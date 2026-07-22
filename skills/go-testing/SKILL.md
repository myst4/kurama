---
name: go-testing
description: >
  Go testing patterns, including table-driven tests, golden files, and
  Bubbletea TUI testing with teatest. Trigger: When writing Go tests, using
  teatest, or adding Go test coverage.
license: Apache-2.0
metadata:
  author: agent-teams-lite
  version: "1.1"
---

## Reference implementation: a per-language testing plugin

This skill is the **reference implementation of a per-language testing plugin**.
The core TDD module (`skills/tdd`) is deliberately language-agnostic: it owns the
RED-GREEN-REFACTOR protocol, anti-patterns, and per-task evidence format, but it
never hard-codes a language. Concrete, per-language testing patterns live in
plugins like this one and reach sub-agents as compact rules through the skill
registry — so a delegated writer picks up idiomatic Go testing guidance without
inflating its context with the full skill.

Use this file as the template when authoring a new testing plugin for another
ecosystem (e.g. `vitest-testing`, `pytest-testing`): keep the frontmatter generic
(no project or vendor names), keep the patterns idiomatic to the language, point
resource links at the language's own docs, and register it in the manifest's
optional group so projects can opt in.

## When to Use

Use this skill when:
- Writing Go unit tests
- Testing Bubbletea TUI components
- Creating table-driven tests
- Adding integration tests
- Using golden file testing

---

## Critical Patterns

### Pattern 1: Table-Driven Tests

Standard Go pattern for multiple test cases:

```go
func TestSomething(t *testing.T) {
    tests := []struct {
        name     string
        input    string
        expected string
        wantErr  bool
    }{
        {
            name:     "valid input",
            input:    "hello",
            expected: "HELLO",
            wantErr:  false,
        },
        {
            name:     "empty input",
            input:    "",
            expected: "",
            wantErr:  true,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result, err := ProcessInput(tt.input)

            if (err != nil) != tt.wantErr {
                t.Errorf("error = %v, wantErr %v", err, tt.wantErr)
                return
            }

            if result != tt.expected {
                t.Errorf("got %q, want %q", result, tt.expected)
            }
        })
    }
}
```

### Pattern 2: Bubbletea Model Testing

Test Model state transitions directly:

```go
func TestModelUpdate(t *testing.T) {
    m := NewModel()

    // Simulate key press
    newModel, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
    m = newModel.(Model)

    if m.Screen != ScreenMainMenu {
        t.Errorf("expected ScreenMainMenu, got %v", m.Screen)
    }
}
```

### Pattern 3: Teatest Integration Tests

Use Charmbracelet's teatest for TUI testing:

```go
func TestInteractiveFlow(t *testing.T) {
    m := NewModel()
    tm := teatest.NewTestModel(t, m)

    // Send keys
    tm.Send(tea.KeyMsg{Type: tea.KeyEnter})
    tm.Send(tea.KeyMsg{Type: tea.KeyDown})
    tm.Send(tea.KeyMsg{Type: tea.KeyEnter})

    // Wait for model to update
    tm.WaitFinished(t, teatest.WithDuration(time.Second))

    // Get final model
    finalModel := tm.FinalModel(t).(Model)

    if finalModel.Screen != ExpectedScreen {
        t.Errorf("wrong screen: got %v", finalModel.Screen)
    }
}
```

### Pattern 4: Golden File Testing

Compare output against saved "golden" files:

```go
func TestOSSelectGolden(t *testing.T) {
    m := NewModel()
    m.Screen = ScreenOSSelect
    m.Width = 80
    m.Height = 24

    output := m.View()

    golden := filepath.Join("testdata", "TestOSSelectGolden.golden")

    if *update {
        os.WriteFile(golden, []byte(output), 0644)
    }

    expected, _ := os.ReadFile(golden)
    if output != string(expected) {
        t.Errorf("output doesn't match golden file")
    }
}
```

---

## Decision Tree

```
Testing a function?
├── Pure function? → Table-driven test
├── Has side effects? → Mock dependencies
├── Returns error? → Test both success and error cases
└── Complex logic? → Break into smaller testable units

Testing TUI component?
├── State change? → Test Model.Update() directly
├── Full flow? → Use teatest.NewTestModel()
├── Visual output? → Use golden file testing
└── Key handling? → Send tea.KeyMsg

Testing system/exec?
├── Mock os/exec? → Use interface + mock
├── Real commands? → Integration test with --short skip
└── File operations? → Use t.TempDir()
```

---

## Code Examples

### Example 1: Testing Key Navigation

```go
func TestCursorNavigation(t *testing.T) {
    tests := []struct {
        name       string
        startPos   int
        key        string
        endPos     int
        numOptions int
    }{
        {"down from 0", 0, "j", 1, 5},
        {"up from 1", 1, "k", 0, 5},
        {"down at bottom", 4, "j", 4, 5}, // stays at bottom
        {"up at top", 0, "k", 0, 5},       // stays at top
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            m := NewModel()
            m.Cursor = tt.startPos
            // Set up options...

            newModel, _ := m.Update(tea.KeyMsg{
                Type:  tea.KeyRunes,
                Runes: []rune(tt.key),
            })
            m = newModel.(Model)

            if m.Cursor != tt.endPos {
                t.Errorf("cursor = %d, want %d", m.Cursor, tt.endPos)
            }
        })
    }
}
```

### Example 2: Testing Screen Transitions

```go
func TestScreenTransitions(t *testing.T) {
    tests := []struct {
        name         string
        startScreen  Screen
        action       tea.Msg
        expectScreen Screen
    }{
        {
            name:         "welcome to main menu",
            startScreen:  ScreenWelcome,
            action:       tea.KeyMsg{Type: tea.KeyEnter},
            expectScreen: ScreenMainMenu,
        },
        {
            name:         "escape from OS select",
            startScreen:  ScreenOSSelect,
            action:       tea.KeyMsg{Type: tea.KeyEsc},
            expectScreen: ScreenMainMenu,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            m := NewModel()
            m.Screen = tt.startScreen

            newModel, _ := m.Update(tt.action)
            m = newModel.(Model)

            if m.Screen != tt.expectScreen {
                t.Errorf("screen = %v, want %v", m.Screen, tt.expectScreen)
            }
        })
    }
}
```

### Example 3: Testing Trainer Exercises

```go
func TestExerciseValidation(t *testing.T) {
    exercise := &Exercise{
        Solutions: []string{"w", "W", "e"},
        Optimal:   "w",
    }

    tests := []struct {
        input   string
        valid   bool
        optimal bool
    }{
        {"w", true, true},
        {"W", true, false},
        {"e", true, false},
        {"x", false, false},
    }

    for _, tt := range tests {
        t.Run(tt.input, func(t *testing.T) {
            valid := ValidateAnswer(exercise, tt.input)
            optimal := IsOptimalAnswer(exercise, tt.input)

            if valid != tt.valid {
                t.Errorf("valid = %v, want %v", valid, tt.valid)
            }
            if optimal != tt.optimal {
                t.Errorf("optimal = %v, want %v", optimal, tt.optimal)
            }
        })
    }
}
```

### Example 4: Mocking System Info

```go
func TestWithMockedSystem(t *testing.T) {
    m := NewModel()

    // Mock system info for testing
    m.SystemInfo = &system.SystemInfo{
        OS:       system.OSMac,
        IsARM:    true,
        HasBrew:  true,
        HomeDir:  t.TempDir(),
    }

    // Now test with controlled environment
    m.SetupInstallSteps()

    // Verify expected steps
    hasHomebrew := false
    for _, step := range m.Steps {
        if step.ID == "homebrew" {
            hasHomebrew = true
        }
    }

    if hasHomebrew {
        t.Error("should not have homebrew step when HasBrew=true")
    }
}
```

---

## Test File Organization

Keep each test file next to the source it exercises, and store golden fixtures in
a sibling `testdata/` directory (the Go toolchain ignores `testdata/` when
building):

```
internal/<package>/
├── model.go
├── model_test.go           # Model tests
├── update.go
├── update_test.go          # Update handler tests
├── view.go
├── view_test.go            # View rendering tests
├── teatest_test.go         # Teatest integration tests
└── testdata/
    ├── TestModelGolden.golden
    └── TestViewGolden.golden
```

---

## Commands

```bash
go test ./...                    # Run all tests
go test -v ./internal/<pkg>/...  # Verbose tests for one package
go test -run TestName ./...      # Run a single test (fast RED-GREEN loop)
go test -cover ./...             # With coverage
go test -update ./...            # Update golden files (if the flag is defined)
go test -short ./...             # Skip integration tests
```

Note: `-update` is not a built-in flag — it works only when the package defines
`var update = flag.Bool("update", false, "update golden files")` (see Pattern 4).

---

## Resources

- **Language-agnostic TDD cycle**: `skills/tdd/SKILL.md` (RED-GREEN-REFACTOR,
  anti-patterns, per-task evidence format) — this plugin only supplies the Go
  specifics.
- **Shared test-runner table**: `skills/_shared/test-runners.md` for the canonical
  `go test` invocations used across the SDD phases.
- **Teatest Docs**: https://github.com/charmbracelet/bubbletea/tree/master/teatest
- **Go testing package**: https://pkg.go.dev/testing
