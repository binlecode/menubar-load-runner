-- Dump the status-item menu's structure — every root row, plus one level of submenu — so RUNBOOK §7's
-- menu walk can be diffed instead of eyeballed. Read-only: it opens the menu, reads titles, and closes
-- it again.
--
--   pgrep -U "$(id -u)" -f '/MenuBarLoadRunner( |$)'      # get the pid
--   osascript tests/menu-dump.applescript <pid>
--
-- Requires Accessibility permission for the calling terminal (System Settings → Privacy & Security →
-- Accessibility), which is why this is a §7 aid and not part of `tests/qa.sh` — the core tier must stay
-- runnable headless and unprivileged.
--
-- THREE THINGS THAT WILL BITE YOU, all found the hard way:
--
-- 1. Resolve the target by UNIX ID, never by name. Every instance is named "MenuBarLoadRunner", and a
--    long-running one is holding the PREVIOUS build's menu — matching by name silently dumps the wrong
--    app, which reads as "no regression" when there is one, or vice versa. Hence the required argument.
-- 2. The status item is `menu bar 1`, not `menu bar 2`. An accessory app (`.accessory`) has no main
--    menu bar, so there is no index 1 for it to sit behind.
-- 3. What you get back is NOT rendered — you cannot screenshot it, and selection marks read as empty
--    because they are a custom `onStateImage`, so `AXMenuItemMarkChar` is blank. This dump proves
--    STRUCTURE (rows, order, nesting, titles). The dot glyphs themselves stay eyes-only here; a
--    synthesized CGEvent click does render the menu if you ever need a real screenshot, but that path
--    needs the item's screen coordinates and AX reports those unreliably on a multi-display setup.

on run argv
	if (count of argv) is not 1 then
		return "usage: osascript tests/menu-dump.applescript <pid>" & linefeed & ¬
			"       pid from: pgrep -U \"$(id -u)\" -f '/MenuBarLoadRunner( |$)'"
	end if
	set targetPid to (item 1 of argv) as integer
	tell application "System Events"
		if not (exists (first application process whose unix id is targetPid)) then
			return "no application process with pid " & targetPid & ¬
				" (is it running? does this terminal have Accessibility permission?)"
		end if
		tell (first application process whose unix id is targetPid)
			click menu bar item 1 of menu bar 1
			delay 1
			set out to ""
			set rootMenu to menu 1 of menu bar item 1 of menu bar 1
			repeat with i from 1 to (count of menu items of rootMenu)
				set rowItem to menu item i of rootMenu
				set rowTitle to title of rowItem
				-- A separator, or a view-based row (the Other Sources disclosure header), has no title.
				if rowTitle is missing value or rowTitle is "" then set rowTitle to "· (separator or view row)"
				set out to out & "  " & i & ". " & rowTitle & linefeed
				if (count of menus of rowItem) > 0 then
					set subMenu to menu 1 of rowItem
					repeat with j from 1 to (count of menu items of subMenu)
						set subTitle to title of (menu item j of subMenu)
						if subTitle is missing value or subTitle is "" then set subTitle to "·"
						set out to out & "        " & i & "." & j & " " & subTitle & linefeed
					end repeat
				end if
			end repeat
			key code 53 -- Escape, so the menu never stays open after a dump
			return out
		end tell
	end tell
end run
