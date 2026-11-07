-- M09 · Clic su un pulsante di OrbitLR per nome (titolo, descrizione o suggerimento), anche dentro le finestrelle.
-- Uso: osascript ax.applescript click "Scarica"   |   osascript ax.applescript dump
on run argv
	set cmd to item 1 of argv
	tell application "System Events"
		tell process "OrbitLR"
			set frontmost to true
			if cmd is "dump" then
				set out to ""
				repeat with w in windows
					set out to out & "WINDOW " & (name of w as text) & linefeed
					repeat with e in (entire contents of w)
						try
							set out to out & (role of e as text) & " | " & (name of e as text) & " | " & (description of e as text) & " | " & (value of e as text) & linefeed
						on error
							try
								set out to out & (role of e as text) & linefeed
							end try
						end try
					end repeat
				end repeat
				return out
			end if
			set target to item 2 of argv
			repeat with w in windows
				set els to entire contents of w
				-- prima i pulsanti delle finestrelle (sheet), poi gli altri: si prende l'ultimo trovato
				set found to missing value
				repeat with e in els
					try
						if role of e is "AXButton" then
							set n to ""
							try
								set n to name of e as text
							end try
							set d to ""
							try
								set d to description of e as text
							end try
							if n is target or d is target then set found to e
						end if
					end try
				end repeat
				if found is not missing value then
					try
						set en to enabled of found
					on error
						set en to "?"
					end try
					click found
					return "cliccato «" & target & "» (abilitato: " & (en as text) & ")"
				end if
			end repeat
			return "NON TROVATO «" & target & "»"
		end tell
	end tell
end run
