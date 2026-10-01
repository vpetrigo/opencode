import { expect, test } from "bun:test"
import { spawnSync } from "node:child_process"
import { readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import { Effect } from "effect"
import { and, desc, eq } from "drizzle-orm"
import { Bus } from "@opencode/core/bus"
import { Database } from "@opencode/core/database/database"
import { AppNodeBuilder } from "@opencode/core/effect/app-node-builder"
import { SessionEvent } from "@opencode/core/session/event"
import { SessionMessage } from "@opencode/core/session/message"
import { SessionProjector } from "@opencode/core/session/projector"
import { SessionSchema } from "@opencode/core/session/schema"
import { SessionStore } from "@opencode/core/session/store"
import { EventSequenceTable } from "@opencode/core/event/sql"
import { SessionMessageTable } from "@opencode/core/session/sql"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { tmpdir } from "./fixture/tmpdir"

const script = path.resolve(import.meta.dir, "../script/fixture-v2-pagination.ts")
const sessionID = SessionSchema.ID.make("ses_fixture_001")

const runScript = (filename: string) => spawnSync(process.execPath, ["run", script, filename], { encoding: "utf8" })

test("fixture data traverses production session pagination and remains appendable", async () => {
  await using directory = await tmpdir("opencode-v2-pagination-")
  const filename = path.join(directory.path, "fixture.sqlite")
  const created = runScript(filename)
  expect(created.status, created.stderr).toBe(0)

  const layer = AppNodeBuilder.build(
    LayerNode.group([Database.node, Bus.node, SessionProjector.node, SessionStore.node]),
    [
      Database.node.replace(Database.configured({ path: filename })),
      Bus.node.replace(Bus.configured({ persist: true })),
    ],
  )
  const report = await Effect.runPromise(
    Effect.scoped(
      Effect.provide(
        Effect.gen(function* () {
          const db = (yield* Database.Service).db
          const bus = yield* Bus.Service
          const store = yield* SessionStore.Service
          const sessions = yield* store.list({ parentID: null, order: "asc" })
          const messages = [] as SessionMessage.Info[]
          let cursor: { id: SessionMessage.ID; direction: "next" } | undefined
          while (true) {
            const page = yield* store.messages({ sessionID, limit: 17, order: "asc", cursor })
            if (page.length === 0) break
            messages.push(...page)
            cursor = { id: page.at(-1)!.id, direction: "next" }
          }
          const terminal = yield* store.messages({ sessionID, limit: 17, order: "asc", cursor })
          const initialWatermark = yield* db
            .select({ seq: EventSequenceTable.seq })
            .from(EventSequenceTable)
            .where(eq(EventSequenceTable.aggregate_id, sessionID))
            .get()
          const maximumMessageSeq = yield* db
            .select({ seq: SessionMessageTable.seq })
            .from(SessionMessageTable)
            .where(eq(SessionMessageTable.session_id, sessionID))
            .orderBy(desc(SessionMessageTable.seq))
            .all()
          const previousWatermark = initialWatermark!.seq

          const inboxID = SessionMessage.ID.make("msg_fixture_append_001")
          yield* bus.publish(SessionEvent.InboxEnqueued, {
            sessionID,
            inboxID,
            item: { type: "user", payload: { text: "Message appended" }, delivery: "steer" },
          })
          yield* bus.publish(SessionEvent.InboxDelivered, { sessionID, inboxID })
          const appended = yield* store.messages({ sessionID, limit: 1, order: "desc" })
          const afterDelivery = yield* db
            .select({ seq: EventSequenceTable.seq })
            .from(EventSequenceTable)
            .where(eq(EventSequenceTable.aggregate_id, sessionID))
            .get()
          yield* bus.publish(SessionEvent.Renamed, { sessionID, title: "Fixture session 001" })
          const finalWatermark = yield* db
            .select({ seq: EventSequenceTable.seq })
            .from(EventSequenceTable)
            .where(eq(EventSequenceTable.aggregate_id, sessionID))
            .get()
          const finalMaximum = yield* db
            .select({ seq: SessionMessageTable.seq })
            .from(SessionMessageTable)
            .where(and(eq(SessionMessageTable.session_id, sessionID), eq(SessionMessageTable.id, appended[0]!.id)))
            .get()

          return {
            sessions,
            messages,
            terminal,
            previousWatermark,
             maximumMessageSeq: maximumMessageSeq[0]!.seq,
            afterDelivery: afterDelivery!.seq,
            finalWatermark: finalWatermark!.seq,
            finalMaximumSeq: finalMaximum!.seq,
            appended,
          }
        }),
        layer,
      ),
    ),
  )

  expect(report.sessions).toHaveLength(60)
  expect(report.sessions.every((session) => session.parentID === undefined)).toBe(true)
  expect(report.sessions.map((session) => session.title).toSorted()).toEqual(
    Array.from({ length: 60 }, (_, index) => `Fixture session ${String(index + 1).padStart(3, "0")}`),
  )
  expect(report.messages).toHaveLength(250)
  expect(new Set(report.messages.map((message) => message.id)).size).toBe(250)
  expect(report.messages.map((message) => (message.type === "user" ? message.text : message.type))).toEqual(
    Array.from({ length: 250 }, (_, index) => `Message ${String(index + 1).padStart(3, "0")}`),
  )
  expect(report.terminal).toEqual([])
  expect(report.previousWatermark).toBeGreaterThanOrEqual(report.maximumMessageSeq)
  expect(report.afterDelivery).toBeGreaterThan(report.previousWatermark)
  expect(report.appended[0]?.type === "user" && report.appended[0].text).toBe("Message appended")
  expect(report.finalMaximumSeq).toBe(report.afterDelivery)
  expect(report.finalWatermark).toBeGreaterThan(report.finalMaximumSeq)
})

test("fixture refuses an existing destination and SQLite sidecars without changing bytes", async () => {
  await using directory = await tmpdir("opencode-v2-pagination-refusal-")
  const existing = path.join(directory.path, "existing.sqlite")
  const existingBytes = Buffer.from("keep existing database bytes")
  await writeFile(existing, existingBytes)
  const existingResult = runScript(existing)
  expect(existingResult.status).not.toBe(0)
  expect(await readFile(existing)).toEqual(existingBytes)

  for (const suffix of ["-wal", "-shm"]) {
    const filename = path.join(directory.path, `sidecar${suffix}.sqlite`)
    const sidecar = `${filename}${suffix}`
    const sidecarBytes = Buffer.from(`keep ${suffix} bytes`)
    await writeFile(sidecar, sidecarBytes)
    const result = runScript(filename)
    expect(result.status).not.toBe(0)
    expect(await readFile(sidecar)).toEqual(sidecarBytes)
  }
})
