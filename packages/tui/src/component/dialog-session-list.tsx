import { createMemo, createResource, createSignal, onMount, Show } from "solid-js"
import path from "path"
import type { SessionInfo } from "@opencode/client"
import { Project } from "@opencode/schema/project"
import { TextAttributes } from "@opentui/core"
import type { RGBA } from "@opentui/core"
import { useDialog } from "../ui/dialog"
import { DialogSelect } from "../ui/dialog-select"
import { useRoute } from "../context/route"
import { useData } from "../context/data"
import { Keymap } from "../context/keymap"
import { Locale } from "../util/locale"
import { useTheme } from "../context/theme"
import { useClient } from "../context/client"
import { useLocal } from "../context/local"
import { createDebouncedSignal } from "../util/signal"
import { useToast } from "../ui/toast"
import { DialogSessionRename } from "./dialog-session-rename"
import { Spinner } from "./spinner"
import { errorMessage } from "../util/error"
import { useSessionTabs } from "../context/session-tabs"
import { useStorage } from "../context/storage"
import { useConfig } from "../config"
import { withTimestampedFallback } from "@opencode/util/session-title-fallback"
import { projectName } from "../util/project"
import { useLocation } from "../context/location"

type DialogSessionListQuery = { directory?: string; project?: string; subpath?: string; search?: string }

export function createDialogSessionPager<T extends { id: string }>(input: {
  list: (query: DialogSessionListQuery & { limit: number; order: "desc"; parentID: null; cursor?: string }) => Promise<{ data: T[]; cursor: { next?: string | null } }>
}) {
  let generation = 0
  let key = ""
  let cursor: string | null | undefined
  let exhausted = false
  let active: number | undefined
  let pending: Promise<{ data: T[]; cursor?: string } | undefined> | undefined
  const entries = new Map<string, T>()
  const removed = new Set<string>()
  const load = async (nextKey: string, query: DialogSessionListQuery, reset = false) => {
    if (reset || key !== nextKey) {
      generation++
      key = nextKey
      cursor = undefined
      exhausted = false
      entries.clear()
    }
    if (active === generation) return pending
    if (exhausted) return { data: [...entries.values()], cursor }
    const requestGeneration = generation
    active = requestGeneration
    const request = (async () => {
      while (true) {
        const response = await input.list({ ...query, limit: 50, order: "desc", parentID: null, ...(cursor ? { cursor } : {}) })
        if (requestGeneration !== generation) return
        const previousSize = entries.size
        for (const item of response.data) if (!removed.has(item.id)) entries.set(item.id, item)
        cursor = response.cursor.next
        exhausted = !cursor
        if (entries.size > previousSize || exhausted) break
      }
      if (requestGeneration !== generation) return
      return { data: [...entries.values()], cursor: cursor ?? undefined }
    })().finally(() => {
      if (active === requestGeneration) active = undefined
    })
    pending = request
    return request
  }
  return {
    load,
    remove: (id: string) => {
      entries.delete(id)
      removed.add(id)
    },
  }
}

export function DialogSessionList() {
  const dialog = useDialog()
  const route = useRoute()
  const data = useData()
  const theme = useTheme().surface("dialog")
  const client = useClient()
  const local = useLocal()
  const sessionTabs = useSessionTabs()
  const config = useConfig().data
  const toast = useToast()
  const activeLocation = useLocation()
  const [filter, setFilter] = createSignal("")
  const shortcuts = Keymap.useShortcuts()
  const [search, setSearch] = createDebouncedSignal("", 150)
  const [toDelete, setToDelete] = createSignal<string>()
  const [prefs, updatePrefs] = useStorage().store("session-list", {
    initial: { allProjects: config.tabs?.scope !== "cwd" },
  })
  const allProjects = () => prefs.allProjects
  const pager = createDialogSessionPager<SessionInfo>({ list: (query) => client.api.session.list(query) })
  const [loadingMore, setLoadingMore] = createSignal(false)
  let searchGeneration = 0
  const pickerLocation = () =>
    (route.data.type === "session" ? data.session.get(route.data.sessionID)?.location : undefined) ??
    activeLocation.ref ??
    data.location.default()

  const [searchResults, { mutate: setSearchResults }] = createResource(
    () => ({
      query: search().trim(),
      allProjects: allProjects(),
      location: pickerLocation(),
    }),
    async ({ query, allProjects, location }) => {
      const generation = ++searchGeneration
      try {
        if (!data.location.info(location)) await data.location.sync(location)
        if (generation !== searchGeneration) return { query, allProjects, sessions: [] as SessionInfo[], cursor: undefined, error: undefined }
        const current = data.location.info(location)
        if (!current) throw new Error("Location unavailable")
        const params = {
          ...(allProjects
            ? {}
            : current.project.id === Project.ID.global
              ? { directory: current.directory }
              : {
                  project: current.project.id,
                  subpath: path.relative(current.project.directory, current.directory).replaceAll("\\", "/"),
                }),
          ...(query ? { search: query } : {}),
        }
        const key = JSON.stringify([query, allProjects, location.directory, params])
        const response = await pager.load(key, params, true)
        if (generation !== searchGeneration) return { query, allProjects, sessions: [] as SessionInfo[], cursor: undefined, error: undefined }
        return { query, allProjects, key, params, locationDirectory: location.directory, generation, sessions: response?.data ?? [], cursor: response?.cursor, error: undefined }
      } catch (error) {
        if (generation !== searchGeneration) return { query, allProjects, sessions: [] as SessionInfo[], cursor: undefined, error: undefined }
        // A transient transport failure must degrade search, not crash the TUI
        // through the root ErrorBoundary when the errored resource is read.
        return { query, allProjects, sessions: [] as SessionInfo[], cursor: undefined, error }
      }
    },
  )

  const currentSessionID = createMemo(() => (route.data.type === "session" ? route.data.sessionID : undefined))
  const localSessions = createMemo(() => {
    const query = filter().trim().toLowerCase()
    const current = data.location.info(pickerLocation())
    const sessions = data.session
      .list()
      .filter(
        (session) =>
          allProjects() ||
          (session.projectID === current?.project.id && session.location.directory === current.directory),
      )
    if (!query) return sessions
    return sessions.filter(
      (session) => !session.parentID && withTimestampedFallback(session).toLowerCase().includes(query),
    )
  })
  const sessions = createMemo(() => {
    const query = filter().trim()
    const local = localSessions()
    if (query !== search().trim()) return searchResults.latest?.sessions ?? local
    if (searchResults.loading) return searchResults.latest?.sessions ?? []
    const result = searchResults()
    if (result?.query !== query || result.allProjects !== allProjects() || result.error) return local
    return result.sessions
  })
  const searchState = createMemo(() => {
    const query = filter().trim()
    if (query !== search().trim() || searchResults.loading)
      return { message: query ? "Searching sessions…" : "Loading sessions…", error: false }
    const result = searchResults()
    if (result?.query === query && result.error)
      return {
        message: query ? "Could not search sessions. Change the search to try again." : "Could not load sessions.",
        error: true,
      }
    return { message: query ? "No sessions found" : "No sessions available", error: false }
  })

  const loadMore = async () => {
    const result = searchResults.latest
    if (!result?.cursor || !result.params || !result.key || result.generation !== searchGeneration || result.query !== filter().trim() || result.allProjects !== allProjects() || result.locationDirectory !== pickerLocation().directory || loadingMore()) return
    setLoadingMore(true)
    try {
      const next = await pager.load(result.key, result.params)
      if (next && result.generation === searchGeneration) setSearchResults((current) => current?.key === result.key ? { ...current, sessions: next.data, cursor: next.cursor } : current)
    } catch (error) {
      toast.show({ message: `Failed to load older sessions: ${errorMessage(error)}`, variant: "error", duration: 5000 })
    } finally {
      setLoadingMore(false)
    }
  }

  const quickSwitchHint = createMemo(() => {
    if (sessionTabs.enabled()) return
    const first = shortcuts.get("session.quick_switch.1")
    const last = shortcuts.get("session.quick_switch.9")
    if (!first || !last) return
    return quickSwitchRange(first, last)
  })
  const quickSwitchFooterHints = createMemo(() => {
    const hint = quickSwitchHint()
    return hint && local.session.slots().length > 0 ? [{ title: "switch", label: hint }] : []
  })
  const currentProjectName = createMemo(() => {
    const current = data.location.info(pickerLocation())
    if (!current) return ""
    const project = data.project.get(current.project.id)
    return projectName(project) ?? ""
  })

  const options = createMemo(() => {
    const today = new Date().toDateString()
    const sessionMap = new Map(
      sessions()
        .filter((session) => !session.parentID)
        .map((session) => [session.id, session]),
    )
    const pinned = sessionTabs.enabled() ? [] : local.session.pinned().filter((sessionID) => sessionMap.has(sessionID))
    const pinnedSet = new Set(pinned)
    const slotByID = new Map(local.session.slots().map((sessionID, index) => [sessionID, index + 1]))

    const option = (session: SessionInfo, category: string) => {
      const directory = session.location.directory
      const project = data.project.get(session.projectID)
      const root = session.subpath ? path.resolve(directory, ...session.subpath.split("/").map(() => "..")) : directory
      const relative = path.relative(project?.canonical ?? root, root)
      const footer =
        relative.startsWith("..") || path.isAbsolute(relative)
          ? Locale.truncate(path.basename(relative), 25)
          : undefined
      const slot = sessionTabs.enabled() ? undefined : slotByID.get(session.id)
      const deleting = toDelete() === session.id
      return {
        title: deleting
          ? `Press ${shortcuts.get("session.delete")} again to confirm`
          : withTimestampedFallback(session),
        value: session.id,
        category,
        footer,
        bg: deleting ? theme.background.action.destructive.focused : undefined,
        fg: deleting ? theme.text.action.destructive.focused : undefined,
        gutter:
          data.session.status(session.id) === "running" ||
          data.session.family(session.id).some((id) => data.session.status(id) === "running")
            ? (color: RGBA) => <Spinner color={color} />
            : slot === undefined
              ? undefined
              : () => <text fg={theme.hue.accent[200]}>{slot}</text>,
      }
    }

    const remaining = sessions()
      .filter((session) => !session.parentID && !pinnedSet.has(session.id))
      .map((session) => {
        const date = new Date(session.time.updated).toDateString()
        return option(session, date === today ? "Today" : date)
      })

    return [...pinned.map((sessionID) => option(sessionMap.get(sessionID)!, "Pinned")), ...remaining]
  })

  onMount(() => dialog.setSize("large"))

  return (
    <DialogSelect
      title="Sessions"
      titleView={
        <box flexDirection="row">
          <text fg={theme.text.base} attributes={TextAttributes.BOLD}>
            Sessions
          </text>
          <Show when={!allProjects() && currentProjectName()}>
            <text fg={theme.text.muted}> for {currentProjectName()}</text>
          </Show>
        </box>
      }
      options={options()}
      skipFilter={true}
      preserveSelection={true}
      current={currentSessionID()}
      onFilter={(query) => {
        setFilter(query)
        setSearch(query)
      }}
      bindings={[
        {
          bind: "ctrl+shift+down",
          title: "Load older sessions",
          group: "Dialog",
          run: () => void loadMore(),
        },
        {
          bind: "ctrl+a",
          title: allProjects() ? "Show current directory sessions" : "Show all project sessions",
          group: "Dialog",
          run: () => {
            void updatePrefs((draft) => {
              draft.allProjects = !draft.allProjects
            }).catch(() => {})
          },
        },
      ]}
      emptyView={
        <box paddingLeft={4} paddingRight={4}>
          <text fg={searchState().error ? theme.text.feedback.error.base : theme.text.muted}>
            {searchState().message}
          </text>
        </box>
      }
      noMatchView={
        <box paddingLeft={4} paddingRight={4}>
          <text fg={searchState().error ? theme.text.feedback.error.base : theme.text.muted}>
            {searchState().message}
          </text>
        </box>
      }
      onMove={(option) => {
        setToDelete(undefined)
        const list = options()
        const index = list.findIndex((item) => item.value === option.value)
        if (index >= list.length - 10) void loadMore()
      }}
      footer={
        <Show when={searchResults.latest?.cursor}>
          <text fg={theme.text.muted} onMouseUp={() => void loadMore()} onKeyDown={(event: { name: string; preventDefault(): void }) => {
            if (event.name !== "return") return
            event.preventDefault()
            void loadMore()
          }}>{loadingMore() ? "Loading older sessions…" : "↓ Load older sessions · Ctrl+Shift+↓ or click"}</text>
        </Show>
      }
      onSelect={(option) => {
        route.navigate({ type: "session", sessionID: option.value })
        dialog.clear()
      }}
      actions={[
        {
          command: "session.pin.toggle",
          title: "pin/unpin",
          hidden: sessionTabs.enabled(),
          onTrigger: (option) => local.session.togglePin(option.value),
        },
        {
          command: "session.delete",
          title: "delete",
          onTrigger: (option: { value: string }) => {
            if (toDelete() !== option.value) {
              setToDelete(option.value)
              return
            }
            void client.api.session
              .remove({ sessionID: option.value })
                .then(() => {
                pager.remove(option.value)
                setSearchResults((result) =>
                  result
                    ? { ...result, sessions: result.sessions.filter((session) => session.id !== option.value) }
                    : result,
                )
              })
              .catch((error) => {
                setToDelete(undefined)
                toast.show({
                  message: `Failed to delete session: ${errorMessage(error)}`,
                  variant: "error",
                  duration: 5000,
                })
              })
          },
        },
        {
          command: "session.rename",
          title: "rename",
          onTrigger: (option: { value: string; title: string }) =>
            DialogSessionRename.show(dialog, option.value, option.title),
        },
      ]}
      footerHints={[
        ...quickSwitchFooterHints(),
        { title: allProjects() ? "current directory" : "all projects", label: "ctrl+a", side: "right" },
      ]}
    />
  )
}

function quickSwitchRange(first: string, last: string) {
  const prefix = first.slice(0, -1)
  if (first.endsWith("1") && last === `${prefix}9`) return `${prefix}1-9`
  return `${first} through ${last}`
}
