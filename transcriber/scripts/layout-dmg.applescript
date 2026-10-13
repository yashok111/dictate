-- Configure only this mounted image, never the user's ordinary Finder windows.
on run arguments
    set volumePath to item 1 of arguments
    set volumeFolder to POSIX file volumePath as alias
    set backgroundFile to POSIX file (volumePath & "/.background/installer.tiff") as alias
    tell application "Finder"
        tell folder volumeFolder
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            -- A 640 × 360 content area plus the compact Finder title bar.
            set bounds of container window to {240, 160, 880, 548}
            set options to icon view options of container window
            set arrangement of options to not arranged
            set icon size of options to 96
            set text size of options to 13
            set label position of options to bottom
            set shows item info of options to false
            set shows icon preview of options to false
            set background picture of options to backgroundFile
            set position of item "Transcriber.app" to {174, 222}
            set position of item "Applications" to {466, 222}
            close
            open
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
