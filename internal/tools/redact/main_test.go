package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestRedactKeepsIdsAndNothingElse(t *testing.T) {
	in := `{"type":"user","uuid":"11111111-2222-3333-4444-555555555555","gitBranch":"fix/customer-acme","signature":"RXJhc2VkVGhpbmtpbmc=",
		"userEmail":"real@person.example","other":{"toolUseID":"toolu_01AbCdEf","agent":"a1b2c3d4e5f607182","hash":"0123abcd@v2",
		"token":"ghp_0123456789abcdefghij0123456789abcdefgh","aws":"AKIA0123456789ABCDEF","host":"db7:5432","user":"juan7732",
		"hexkey":"0123456789abcdef0123456789abcdef","text":"mail real@person.example about 42"},
		"trackedFileBackups":{"/Users/real/secret-project/main.go":{"backupFileName":"0123abcd@v2"}}}`
	var v map[string]any
	if err := json.Unmarshal([]byte(in), &v); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(redact(v, ""))
	out := string(b)
	for _, gone := range []string{"customer", "acme", "RXJhc2Vk", "real@person", "ghp_0123", "AKIA0123", "db7", "juan7732", "0123456789abcdef0123456789abcdef", "secret-project", "/Users/real"} {
		if strings.Contains(out, gone) {
			t.Errorf("%q survived:\n%s", gone, out)
		}
	}
	for _, kept := range []string{"11111111-2222-3333-4444-555555555555", "toolu_01AbCdEf", "a1b2c3d4e5f607182", `"0123abcd@v2"`, `"signature":"sig"`,
		`"userEmail":"user@example.com"`, "xxxx user@example.com xxxxx 00", `"/Xxxxx/xxxx/xxxxxx-xxxxxxx/xxxx.xx"`} {
		if !strings.Contains(out, kept) {
			t.Errorf("%q is missing:\n%s", kept, out)
		}
	}
}
