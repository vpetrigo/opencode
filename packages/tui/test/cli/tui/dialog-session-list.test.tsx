/** @jsxImportSource @opentui/solid */
import { expect, test } from "bun:test"
import { testRender } from "@opentui/solid"
import { onMount } from "solid-js"
import { DialogSessionList } from "../../../src/component/dialog-session-list"
import { ConfigProvider } from "../../../src/config"
import { ArgsProvider } from "../../../src/context/args"
import { ClientProvider } from "../../../src/context/client"
import { DataProvider, useData } from "../../../src/context/data"
import { Keymap } from "../../../src/context/keymap"
import { LocalProvider } from "../../../src/context/local"
import { LocationProvider } from "../../../src/context/location"
import { PermissionProvider } from "../../../src/context/permission"
import { RouteProvider, useRoute } from "../../../src/context/route"
import { TuiAppProvider } from "../../../src/context/runtime"
import { SessionTabsProvider } from "../../../src/context/session-tabs"
import { StorageProvider, useStorage } from "../../../src/context/storage"
import { ThemeProvider } from "../../../src/context/theme"
import { DialogProvider, useDialog } from "../../../src/ui/dialog"
import { ToastProvider } from "../../../src/ui/toast"
import { createApi, createEventStream, createFetch, json } from "../../fixture/tui-client"
import { emptyThemeSource, tmpdir } from "../../fixture/fixture"
import { TestTuiContexts } from "../../fixture/tui-environment"
import { createTuiResolvedConfig } from "../../fixture/tui-runtime"
import { createDialogSessionPager } from "../../../src/component/dialog-session-list"

test("session picker appends cursor pages without losing the active filters", async () => {
  const calls: { cursor?: string; search?: string; project?: string; parentID?: null; limit?: number; order?: string }[] = []
  const pager = createDialogSessionPager({
    list: async (query) => {
      calls.push(query)
      return query.cursor
        ? { data: [{ id: "ses_50" }, ...Array.from({ length: 50 }, (_, index) => ({ id: `ses_${index + 51}` }))], cursor: {} }
        : { data: Array.from({ length: 50 }, (_, index) => ({ id: `ses_${index}` })), cursor: { next: "older" } }
    },
  })
  const query = { project: "project-a", search: "work" }
  expect((await pager.load("project-a:work", query, true))?.data).toHaveLength(50)
  expect((await pager.load("project-a:work", query))?.data).toHaveLength(101)
  expect(calls[1]).toMatchObject({ cursor: "older", project: "project-a", search: "work", parentID: null, order: "desc" })
  expect(calls[1]?.limit).toBe(50)
  expect(calls[1]?.cursor).toBe("older")
})

test("session picker exhausts empty terminal pages and deduplicates session IDs", async () => {
  let calls = 0
  const pager = createDialogSessionPager({
    list: async (query) => {
      calls++
      if (query.cursor === "empty") return { data: [], cursor: {} }
      return { data: [{ id: "ses_same" }], cursor: { next: "empty" } }
    },
  })
  const first = await pager.load("all", {}, true)
  expect(first?.data.map((session) => session.id)).toEqual(["ses_same"])
  const exhausted = await pager.load("all", {})
  expect(exhausted?.data.map((session) => session.id)).toEqual(["ses_same"])
  expect(exhausted?.cursor).toBeUndefined()
  await pager.load("all", {})
  expect(calls).toBe(2)
})

test("session picker discards pages from a stale search", async () => {
  let resolveOld!: (value: { data: { id: string }[]; cursor: { next?: string | null } }) => void
  const pager = createDialogSessionPager<{ id: string }>({
    list: (query) => query.search === "old"
      ? new Promise<{ data: { id: string }[]; cursor: { next?: string | null } }>((resolve) => { resolveOld = resolve })
      : Promise.resolve({ data: [{ id: "ses_new" }], cursor: {} }),
  })
  const old = pager.load("old", { search: "old" }, true)
  const current = await pager.load("new", { search: "new" }, true)
  resolveOld({ data: [{ id: "ses_old" }], cursor: {} })
  await old
  expect(current?.data.map((session) => session.id)).toEqual(["ses_new"])
})

test("deleted sessions stay removed when another cursor page is appended", async () => {
  const pager = createDialogSessionPager({
    list: async (query) => query.cursor
      ? { data: [{ id: "ses_deleted" }, { id: "ses_keep" }], cursor: {} }
      : { data: [{ id: "ses_deleted" }], cursor: { next: "older" } },
  })
  const query = {}
  await pager.load("all", query, true)
  pager.remove("ses_deleted")
  const result = await pager.load("all", query)
  expect(result?.data.map((session) => session.id)).toEqual(["ses_keep"])
})

test("scopes sessions to the active session location", async () => {
  const active = "/tmp/opencode/project-b"
  const events = createEventStream()
  const requestedProjects: string[] = []
  const calls = createFetch((url) => {
    if (url.pathname === "/api/location") {
      const directory = url.searchParams.get("location[directory]") ?? process.cwd()
      const project = directory === active ? "proj_b" : "proj_a"
      return json({ directory, project: { id: project, directory, canonical: directory } })
    }
    if (url.pathname !== "/api/session") return undefined
    // Family syncs list children by parentID; only project-scoped list requests matter here.
    const parentID = url.searchParams.get("parentID")
    if (parentID && parentID !== "null") return json({ data: [], cursor: {} })
    const project = url.searchParams.get("project") ?? ""
    requestedProjects.push(project)
    return json({
      data: [
        {
          id: project === "proj_b" ? "ses_b" : "ses_a",
          projectID: project,
          cost: 0,
          tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
          time: { created: 1, updated: 2 },
          title: project === "proj_b" ? "Project B session" : "Project A session",
          location: { directory: project === "proj_b" ? active : process.cwd() },
        },
      ],
      cursor: {},
    })
  }, events)
  const temporary = await tmpdir()
  let storage!: ReturnType<typeof useStorage>

  function Probe() {
    const data = useData()
    const dialog = useDialog()
    const route = useRoute()
    storage = useStorage()
    onMount(() => {
      data.session.remember({
        id: "ses_active",
        projectID: "proj_b",
        cost: 0,
        tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
        time: { created: 1, updated: 3 },
        title: "Active session",
        location: { directory: active },
      })
      route.navigate({ type: "session", sessionID: "ses_active" })
      dialog.replace(() => <DialogSessionList />)
    })
    return null
  }

  const app = await testRender(
    () => (
      <TestTuiContexts paths={{ state: temporary.path }}>
        <TuiAppProvider value={{ name: "test", version: "test", channel: "test" }}>
          <StorageProvider>
            <ArgsProvider>
              <ConfigProvider config={createTuiResolvedConfig()}>
                <Keymap.Provider>
                  <ToastProvider>
                    <RouteProvider>
                      <ClientProvider api={createApi(calls.fetch)}>
                        <PermissionProvider>
                          <DataProvider directory={process.cwd()}>
                            <LocationProvider>
                              <SessionTabsProvider>
                                <ThemeProvider mode="dark" source={emptyThemeSource}>
                                  <LocalProvider>
                                    <DialogProvider>
                                      <Probe />
                                    </DialogProvider>
                                  </LocalProvider>
                                </ThemeProvider>
                              </SessionTabsProvider>
                            </LocationProvider>
                          </DataProvider>
                        </PermissionProvider>
                      </ClientProvider>
                    </RouteProvider>
                  </ToastProvider>
                </Keymap.Provider>
              </ConfigProvider>
            </ArgsProvider>
          </StorageProvider>
        </TuiAppProvider>
      </TestTuiContexts>
    ),
    { width: 100, height: 30, kittyKeyboard: true },
  )
  app.renderer.start()

  try {
    const frame = await app.waitForFrame((value) => value.includes("Project B session"))
    expect(frame).not.toContain("Project A session")
    expect(requestedProjects.at(-1)).toBe("proj_b")
  } finally {
    app.renderer.destroy()
    await storage.flush()
    await temporary[Symbol.asyncDispose]()
  }
})

test("navigates into cursor-loaded sessions and selects the page-two session", async () => {
  const events = createEventStream()
  const temporary = await tmpdir()
  let storage!: ReturnType<typeof useStorage>
  let route!: ReturnType<typeof useRoute>
  let sessionCalls = 0
  const calls = createFetch((url) => {
    if (url.pathname === "/api/location") {
      const directory = url.searchParams.get("location[directory]") ?? process.cwd()
      return json({ directory, project: { id: "project-a", directory, canonical: directory } })
    }
    if (url.pathname !== "/api/session") return undefined
    const parentID = url.searchParams.get("parentID")
    if (parentID && parentID !== "null") return json({ data: [], cursor: {} })
    sessionCalls++
    const pageTwo = url.searchParams.get("cursor") === "older"
    const data = Array.from({ length: 50 }, (_, index) => ({
      id: pageTwo ? `ses_page2_${index}` : `ses_page1_${index}`,
      projectID: "project-a",
      cost: 0,
      tokens: { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } },
      time: { created: 1_700_000_000_000 + index, updated: 1_700_000_000_000 + index },
      title: pageTwo ? `Page two session ${index}` : `Page one session ${index}`,
      location: { directory: process.cwd() },
    }))
    return json({ data, cursor: pageTwo ? {} : { next: "older" } })
  }, events)

  function Probe() {
    const dialog = useDialog()
    route = useRoute()
    storage = useStorage()
    onMount(() => dialog.replace(() => <DialogSessionList />))
    return null
  }

  const app = await testRender(
    () => (
      <TestTuiContexts paths={{ state: temporary.path }}>
        <TuiAppProvider value={{ name: "test", version: "test", channel: "test" }}>
          <StorageProvider><ArgsProvider><ConfigProvider config={createTuiResolvedConfig()}><Keymap.Provider>
            <ToastProvider><RouteProvider><ClientProvider api={createApi(calls.fetch)}><PermissionProvider>
              <DataProvider directory={process.cwd()}><LocationProvider><SessionTabsProvider>
                <ThemeProvider mode="dark" source={emptyThemeSource}><LocalProvider><DialogProvider><Probe /></DialogProvider></LocalProvider></ThemeProvider>
              </SessionTabsProvider></LocationProvider></DataProvider>
            </PermissionProvider></ClientProvider></RouteProvider></ToastProvider>
          </Keymap.Provider></ConfigProvider></ArgsProvider></StorageProvider>
        </TuiAppProvider>
      </TestTuiContexts>
    ),
    { width: 100, height: 30, kittyKeyboard: true },
  )
  app.renderer.start()
  try {
    await app.waitForFrame((frame) => frame.includes("Page one session 0"))
    for (let page = 0; page < 4; page++) app.mockInput.pressKey("\u001B[6~")
    await app.waitForFrame((frame) => frame.includes("Page one session 40"))
    await new Promise((resolve) => setTimeout(resolve, 25))
    await app.renderOnce()
    expect(sessionCalls).toBe(2)
    app.mockInput.pressKey("\u001B[6~")
    app.mockInput.pressEnter()
    await app.waitForFrame(() => route.data.type === "session" && route.data.sessionID === "ses_page2_0")
    expect(route.data).toMatchObject({ type: "session", sessionID: "ses_page2_0" })
  } finally {
    app.renderer.destroy()
    await storage.flush()
    await temporary[Symbol.asyncDispose]()
  }
})
