package deckreel

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// All paths are passed as AppleScript argv, never interpolated as source.
const exportScript = `on run argv
 set inputFile to POSIX file (item 1 of argv)
 set outputFile to POSIX file (item 2 of argv)
 tell application "Microsoft PowerPoint"
  set ownedPresentation to missing value
  try
   open inputFile
   set ownedPresentation to active presentation
   save ownedPresentation in outputFile as save as PDF
   close ownedPresentation saving no
  on error errorMessage number errorNumber
   if ownedPresentation is not missing value then
    try
     close ownedPresentation saving no
    end try
   end if
   error errorMessage number errorNumber
  end try
 end tell
end run`

type PowerPoint struct{}

func (PowerPoint) Version(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	b, e := exec.CommandContext(ctx, "/usr/bin/osascript", "-e", `tell application "Microsoft PowerPoint" to get version`).Output()
	if e != nil {
		return "", fmt.Errorf("PowerPoint unavailable or automation not permitted; allow access in System Settings > Privacy & Security > Automation")
	}
	return string(b), nil
}
func (PowerPoint) Export(ctx context.Context, input, output string) error {
	cache, e := os.UserCacheDir()
	if e != nil {
		return e
	}
	lock, e := Lock(filepath.Join(cache, "DeckReel", "powerpoint.lock"))
	if e != nil {
		return e
	}
	defer lock.Close()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/osascript", "-e", exportScript, input, output)
	if _, e = cmd.Output(); e != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("PowerPoint PDF export failed; check Automation permission and open dialogs (see docs/development.md)")
	}
	st, e := os.Stat(output)
	if e != nil || st.Size() == 0 {
		return fmt.Errorf("PowerPoint did not create PDF")
	}
	return nil
}
