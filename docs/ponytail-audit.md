# ponytail-audit (2026-07-22)

`delete:` unused `copy_path_clipboard` wrapper. nothing. [cw]
`delete:` unused `list_worktree_dirs`. nothing. [cw]
`yagni:` `list --interactive` no-op flag. TTY auto path only. [cw]
`yagni:` `WPATH` parallel to `RESOLVED_PATH`. use `RESOLVED_PATH`. [cw]
`shrink:` five name-only cmds duplicated Usage/resolve. `require_named`. [cw]
`shrink:` `cmd_clean` re-parsed porcelain. reuse `collect_worktree_rows`. [cw]
`shrink:` `merge_base_branch` re-queried main path. use `REPO_ROOT`. [cw]

Left alone (load-bearing / product):
- interactive TTY menu + spinner (core UX)
- `is_effectively_merged` + reflog guard (data-loss regressions)
- check.sh suite size (regression harness)

net: -43 lines (`cw` 1245→1202), -0 deps.
