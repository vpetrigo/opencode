import { access, open } from "node:fs/promises"
import path from "node:path"
import { Effect, Logger } from "effect"
import { AppNodeBuilder } from "../src/effect/app-node-builder"
import { LayerNode } from "@opencode/util/effect/layer-node"
import { Bus } from "../src/bus"
import { Database } from "../src/database/database"
import { SessionEvent } from "../src/session/event"
import { SessionMessage } from "../src/session/message"
import { SessionProjector } from "../src/session/projector"
import { SessionSchema } from "../src/session/schema"
import { ProjectTable } from "../src/project/sql"
import { Project } from "@opencode/schema/project"
import { AbsolutePath } from "../src/schema"

const output = process.argv[2]
if (!output || process.argv.length !== 3 || !path.isAbsolute(output)) {
  console.error("Usage: bun run script/fixture-v2-pagination.ts <new-absolute-output.sqlite>")
  process.exit(1)
}

const filename = path.resolve(output)
const directory = path.dirname(filename)
await access(directory).catch(() => {
  console.error(`Output parent directory does not exist: ${directory}`)
  process.exit(1)
})

for (const sidecar of [`${filename}-wal`, `${filename}-shm`]) {
  await access(sidecar).then(
    () => {
      console.error(`Refusing existing SQLite sidecar: ${sidecar}`)
      process.exit(1)
    },
    () => undefined,
  )
}

const reservation = await open(filename, "wx").catch((error: NodeJS.ErrnoException) => {
  if (error.code === "EEXIST") {
    console.error(`Refusing to overwrite existing database: ${filename}`)
    process.exit(1)
  }
  throw error
})
await reservation.close()

const layer = AppNodeBuilder.build(
  LayerNode.group([Database.node, Bus.node, SessionProjector.node]),
  [
    Database.node.replace(Database.configured({ path: filename })),
    Bus.node.replace(Bus.configured({ persist: true })),
  ],
)
const program = Effect.gen(function* () {
  const db = (yield* Database.Service).db
  const bus = yield* Bus.Service
  yield* db
    .insert(ProjectTable)
    .values({ id: Project.ID.global, worktree: AbsolutePath.make(directory), sandboxes: [] })
    .onConflictDoNothing()
    .run()

  for (let index = 1; index <= 60; index++) {
    const suffix = String(index).padStart(3, "0")
    const sessionID = SessionSchema.ID.make(`ses_fixture_${suffix}`)
    yield* bus.publish(SessionEvent.Created, {
      sessionID,
      projectID: Project.ID.global,
      location: { directory: AbsolutePath.make(directory) },
      slug: `fixture-session-${suffix}`,
      title: `Fixture session ${suffix}`,
      version: "2.0.21",
    })
  }

  const sessionID = SessionSchema.ID.make("ses_fixture_001")
  for (let index = 1; index <= 250; index++) {
    const suffix = String(index).padStart(3, "0")
    const inboxID = SessionMessage.ID.make(`msg_fixture_${suffix}`)
    yield* bus.publish(SessionEvent.InboxEnqueued, {
      sessionID,
      inboxID,
      item: { type: "user", payload: { text: `Message ${suffix}` }, delivery: "steer" },
    })
    yield* bus.publish(SessionEvent.InboxDelivered, { sessionID, inboxID })
  }
  console.log(`Created 60 sessions and 250 messages in ${filename}`)
}).pipe(Effect.scoped, Effect.provide(layer), Effect.provide(Logger.layer([])))

await Effect.runPromise(program)
