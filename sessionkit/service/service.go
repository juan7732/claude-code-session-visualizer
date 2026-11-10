// Package service keeps the archiver running without anyone remembering to:
// it installs, removes and inspects a launchd agent that runs `skit serve`
// (which watches Claude Code's projects and archives sessions as they settle)
// from login on, restarted if it stops.
//
// macOS only for now. The plist is the one file skit writes outside its home:
// launchd reads agents from ~/Library/LaunchAgents and nowhere else.
package service

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

// Label is the launchd label of the agent.
const Label = "dev.sessionkit.skit"

// ErrUnsupported is returned off macOS.
var ErrUnsupported = errors.New("skit service manages a launchd agent, which is macOS only for now; elsewhere run `skit serve` under your own supervisor")

// Status is the state of the agent.
type Status struct {
	Supported bool   `json:"supported"` // false off macOS
	Installed bool   `json:"installed"` // the plist exists
	Running   bool   `json:"running"`   // launchd has it loaded and the process is up
	PID       int    `json:"pid,omitempty"`
	Label     string `json:"label"`
	Plist     string `json:"plist"`
	Binary    string `json:"binary,omitempty"` // the skit the agent runs
	// BinaryExists is false when the agent points at a skit that is gone
	// (the app was moved, the build directory cleaned).
	BinaryExists bool   `json:"binary_exists"`
	Log          string `json:"log,omitempty"`
	Detail       string `json:"detail,omitempty"`
}

// Config says what the agent should run.
type Config struct {
	Binary    string // absolute path of skit
	SkitHome  string // skit's home; the log goes here
	ClaudeDir string // set CLAUDE_CONFIG_DIR for the agent when not empty
	// SetSkitHome puts SKIT_HOME in the agent's environment (when the caller
	// runs with a non-default home).
	SetSkitHome bool
}

// launchd is the seam to the system: where agents live, which domain they are
// loaded into, and how launchctl is run.
type launchd struct {
	agentsDir string
	domain    string // gui/<uid>
	run       func(args ...string) ([]byte, error)
}

func system() (*launchd, error) {
	if runtime.GOOS != "darwin" {
		return nil, ErrUnsupported
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	return &launchd{
		agentsDir: filepath.Join(h, "Library", "LaunchAgents"),
		domain:    "gui/" + strconv.Itoa(os.Getuid()),
		run: func(args ...string) ([]byte, error) {
			return exec.Command("launchctl", args...).CombinedOutput()
		},
	}, nil
}

// Install writes the agent's plist and loads it, replacing a previous one.
// It is safe to run again: after moving the binary, or to pick up a new one.
func Install(c Config) (Status, error) {
	l, err := system()
	if err != nil {
		return Status{Label: Label}, err
	}
	return l.install(c)
}

// Uninstall unloads the agent and removes its plist. The archive is untouched.
func Uninstall() (Status, error) {
	l, err := system()
	if err != nil {
		return Status{Label: Label}, err
	}
	return l.uninstall()
}

// Inspect reports the agent's state. It never fails: off macOS, Supported is false.
func Inspect() Status {
	l, err := system()
	if err != nil {
		return Status{Label: Label, Detail: err.Error()}
	}
	return l.inspect()
}

func (l *launchd) plistPath() string { return filepath.Join(l.agentsDir, Label+".plist") }

func (l *launchd) install(c Config) (Status, error) {
	if !filepath.IsAbs(c.Binary) {
		return l.inspect(), fmt.Errorf("the agent needs an absolute path to skit, got %q", c.Binary)
	}
	if _, err := os.Stat(c.Binary); err != nil {
		return l.inspect(), fmt.Errorf("skit binary: %w", err)
	}
	if err := os.MkdirAll(l.agentsDir, 0o755); err != nil {
		return l.inspect(), err
	}
	if err := os.MkdirAll(c.SkitHome, 0o700); err != nil {
		return l.inspect(), err
	}
	tmp := l.plistPath() + ".tmp"
	if err := os.WriteFile(tmp, Plist(c), 0o644); err != nil {
		return l.inspect(), err
	}
	if err := os.Rename(tmp, l.plistPath()); err != nil {
		return l.inspect(), err
	}
	// Unload a previous copy first; "not loaded" is the usual answer and is fine.
	_, _ = l.run("bootout", l.domain+"/"+Label)
	if out, err := l.run("bootstrap", l.domain, l.plistPath()); err != nil {
		return l.inspect(), fmt.Errorf("launchctl bootstrap: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return l.inspect(), nil
}

func (l *launchd) uninstall() (Status, error) {
	_, _ = l.run("bootout", l.domain+"/"+Label)
	if err := os.Remove(l.plistPath()); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return l.inspect(), err
	}
	return l.inspect(), nil
}

var (
	pidLine   = regexp.MustCompile(`(?m)^\s*pid = (\d+)`)
	stateLine = regexp.MustCompile(`(?m)^\s*state = (\S+)`)
)

func (l *launchd) inspect() Status {
	st := Status{Supported: true, Label: Label, Plist: l.plistPath()}
	b, err := os.ReadFile(l.plistPath())
	if err != nil {
		st.Detail = "not installed: sessions are archived only while `skit serve` runs or when `skit archive` is run"
		return st
	}
	st.Installed = true
	if c, ok := parsePlist(b); ok {
		st.Binary, st.Log = c.binary, c.log
		_, statErr := os.Stat(c.binary)
		st.BinaryExists = statErr == nil
	}
	out, err := l.run("print", l.domain+"/"+Label)
	if err != nil {
		st.Detail = "installed but not loaded; run `skit service install` again"
		return st
	}
	if m := pidLine.FindSubmatch(out); m != nil {
		st.PID, _ = strconv.Atoi(string(m[1]))
	}
	if m := stateLine.FindSubmatch(out); m != nil && string(m[1]) == "running" && st.PID > 0 {
		st.Running = true
	}
	switch {
	case !st.BinaryExists:
		st.Detail = "the agent points at a skit that no longer exists; run `skit service install` from the current one"
	case !st.Running:
		st.Detail = "loaded but not running; see the log"
	}
	return st
}

// Plist renders the agent's property list.
func Plist(c Config) []byte {
	var b bytes.Buffer
	esc := func(s string) string {
		var e bytes.Buffer
		_ = xml.EscapeText(&e, []byte(s))
		return e.String()
	}
	log := filepath.Join(c.SkitHome, "serve.log")
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by "skit service install". Remove with "skit service uninstall". -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>` + Label + `</string>
	<key>ProgramArguments</key>
	<array>
		<string>` + esc(c.Binary) + `</string>
		<string>serve</string>
		<string>--quiet</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>30</integer>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>` + esc(log) + `</string>
	<key>StandardErrorPath</key>
	<string>` + esc(log) + `</string>
`)
	env := map[string]string{}
	if c.SetSkitHome {
		env["SKIT_HOME"] = c.SkitHome
	}
	if c.ClaudeDir != "" {
		env["CLAUDE_CONFIG_DIR"] = c.ClaudeDir
	}
	if len(env) > 0 {
		b.WriteString("\t<key>EnvironmentVariables</key>\n\t<dict>\n")
		for _, k := range []string{"CLAUDE_CONFIG_DIR", "SKIT_HOME"} {
			if v, ok := env[k]; ok {
				b.WriteString("\t\t<key>" + k + "</key>\n\t\t<string>" + esc(v) + "</string>\n")
			}
		}
		b.WriteString("\t</dict>\n")
	}
	b.WriteString("</dict>\n</plist>\n")
	return b.Bytes()
}

type plistFacts struct{ binary, log string }

// parsePlist reads back the two facts status needs from a plist this package wrote.
func parsePlist(b []byte) (plistFacts, bool) {
	var doc struct {
		Dict struct {
			Items []struct {
				XMLName xml.Name
				Value   string   `xml:",chardata"`
				Strings []string `xml:"string"`
			} `xml:",any"`
		} `xml:"dict"`
	}
	if err := xml.Unmarshal(b, &doc); err != nil {
		return plistFacts{}, false
	}
	var f plistFacts
	key := ""
	for _, it := range doc.Dict.Items {
		switch it.XMLName.Local {
		case "key":
			key = it.Value
		case "array":
			if key == "ProgramArguments" && len(it.Strings) > 0 {
				f.binary = it.Strings[0]
			}
		case "string":
			if key == "StandardErrorPath" {
				f.log = it.Value
			}
		}
	}
	return f, f.binary != ""
}
