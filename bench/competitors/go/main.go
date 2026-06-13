// santhosh-tekuri/jsonschema v6 adapter for the cross-language bench protocol.
// Reads bench/workloads/manifest.json, runs every crossLanguage workload, and
// prints one protocol JSON line per workload to stdout. Timing is in-process
// (see bench/PROTOCOL.md).
//
// Setup:  cd bench/competitors/go && go mod tidy
// Run:    go run . [path/to/manifest.json]
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/santhosh-tekuri/jsonschema/v6"
)

type defaults struct {
	Warmup     int `json:"warmup"`
	Iterations int `json:"iterations"`
	Samples    int `json:"samples"`
}

type workload struct {
	Name          string   `json:"name"`
	Schema        string   `json:"schema"`
	Valid         []string `json:"valid"`
	Invalid       []string `json:"invalid"`
	Warmup        *int     `json:"warmup"`
	Iterations    *int     `json:"iterations"`
	Samples       *int     `json:"samples"`
	CrossLanguage bool     `json:"crossLanguage"`
}

type manifest struct {
	Defaults  defaults   `json:"defaults"`
	Workloads []workload `json:"workloads"`
}

var sink int

func pick(override *int, def int) int {
	if override != nil {
		return *override
	}
	return def
}

func loadJSON(path string) any {
	b, err := os.ReadFile(path)
	if err != nil {
		panic(err)
	}
	v, err := jsonschema.UnmarshalJSON(strings.NewReader(string(b)))
	if err != nil {
		panic(err)
	}
	return v
}

func compileSchema(id string, doc any) *jsonschema.Schema {
	c := jsonschema.NewCompiler()
	if err := c.AddResource(id, doc); err != nil {
		panic(err)
	}
	sch, err := c.Compile(id)
	if err != nil {
		panic(err)
	}
	return sch
}

// measure runs op iters times per sample over samples samples; returns per-op
// min and median nanoseconds.
func measure(samples, iters int, op func()) (float64, float64) {
	times := make([]float64, samples)
	for s := 0; s < samples; s++ {
		t0 := nowNs()
		for i := 0; i < iters; i++ {
			op()
		}
		times[s] = float64(nowNs()-t0) / float64(iters)
	}
	sort.Float64s(times)
	return times[0], times[samples/2]
}

func main() {
	manifestPath := filepath.Join("..", "..", "workloads", "manifest.json")
	if len(os.Args) > 1 {
		manifestPath = os.Args[1]
	}
	root := filepath.Dir(manifestPath)

	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		panic(err)
	}
	var m manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		panic(err)
	}

	enc := json.NewEncoder(os.Stdout)
	for _, w := range m.Workloads {
		if !w.CrossLanguage {
			continue
		}
		samples := pick(w.Samples, m.Defaults.Samples)
		iters := pick(w.Iterations, m.Defaults.Iterations)
		warmup := pick(w.Warmup, m.Defaults.Warmup)

		schemaDoc := loadJSON(filepath.Join(root, w.Schema))
		valid := make([]any, len(w.Valid))
		for i, p := range w.Valid {
			valid[i] = loadJSON(filepath.Join(root, p))
		}
		invalid := make([]any, len(w.Invalid))
		for i, p := range w.Invalid {
			invalid[i] = loadJSON(filepath.Join(root, p))
		}
		validBytes := fileBytes(filepath.Join(root, w.Valid[0]))

		compileMin, compileMedian := measure(samples, 1, func() {
			s := compileSchema("schema.json", schemaDoc)
			if s != nil {
				sink++
			}
		})

		validator := compileSchema("schema.json", schemaDoc)
		correct := true
		for _, x := range valid {
			if validator.Validate(x) != nil {
				correct = false
			}
		}
		for _, x := range invalid {
			if validator.Validate(x) == nil {
				correct = false
			}
		}

		timeValidate := func(instance any) (float64, float64) {
			for i := 0; i < warmup; i++ {
				if validator.Validate(instance) == nil {
					sink++
				}
			}
			return measure(samples, iters, func() {
				if validator.Validate(instance) == nil {
					sink++
				}
			})
		}
		vMin, vMed := timeValidate(valid[0])
		ivMin, ivMed := timeValidate(invalid[0])

		mbPerSec := 0.0
		if vMed > 0 {
			mbPerSec = float64(validBytes) * 1000 / vMed
		}
		enc.Encode(map[string]any{
			"implementation":           "santhosh-tekuri",
			"libraryVersion":           moduleVersion(),
			"workload":                 w.Name,
			"compileNsMin":             compileMin,
			"compileNsMedian":          compileMedian,
			"validateValidNsMin":       vMin,
			"validateValidNsMedian":    vMed,
			"validateInvalidNsMin":     ivMin,
			"validateInvalidNsMedian":  ivMed,
			"bytes":                    validBytes,
			"mbPerSec":                 mbPerSec,
			"correctnessOk":            correct,
		})
	}
	if sink < 0 {
		fmt.Fprintln(os.Stderr, sink)
	}
}

func fileBytes(path string) int {
	info, err := os.Stat(path)
	if err != nil {
		panic(err)
	}
	return int(info.Size())
}
