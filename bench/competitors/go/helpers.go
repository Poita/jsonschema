package main

import (
	"runtime/debug"
	"time"
)

func nowNs() int64 {
	return time.Now().UnixNano()
}

// moduleVersion reports the resolved jsonschema/v6 version from the build's
// dependency info, or "unknown" when built outside a module context.
func moduleVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "unknown"
	}
	for _, dep := range info.Deps {
		if dep.Path == "github.com/santhosh-tekuri/jsonschema/v6" {
			return dep.Version
		}
	}
	return "unknown"
}
