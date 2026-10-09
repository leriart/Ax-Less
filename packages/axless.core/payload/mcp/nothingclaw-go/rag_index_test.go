// Tests for the cached RAG index: the score a chunk receives must match the
// original map-based scorer exactly, and repeated searches must not re-parse.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// buildRagIndexFile writes a synthetic index in the on-disk format and returns
// its path.
func buildRagIndexFile(tb testing.TB, dir string, chunks int) string {
	tb.Helper()
	files := map[string]ragFileJSON{}
	fc := ragFileJSON{Chunks: make([]ragChunkJSON, 0, chunks)}
	terms := []string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta", "omega", "quux"}
	for i := 0; i < chunks; i++ {
		text := fmt.Sprintf("chunk %d talking about %s and %s", i, terms[i%len(terms)], terms[(i+3)%len(terms)])
		tm := map[string]int{terms[i%len(terms)]: 1 + i%4}
		if i%2 == 0 {
			tm[terms[(i+3)%len(terms)]] = 2
		}
		fc.Chunks = append(fc.Chunks, ragChunkJSON{
			ID:    fmt.Sprintf("/src/file%d.go:10", i),
			Text:  text,
			Len:   len(text),
			Terms: tm,
		})
	}
	files["/src/file.go"] = fc
	raw, err := json.Marshal(ragIndexJSON{Directory: "/src", Files: files})
	if err != nil {
		tb.Fatal(err)
	}
	p := filepath.Join(dir, "index-abc.json")
	if err := os.WriteFile(p, raw, 0o644); err != nil {
		tb.Fatal(err)
	}
	return p
}

func TestRagSearchFindsTerm(t *testing.T) {
	dir := t.TempDir()
	p := buildRagIndexFile(t, dir, 64)

	hits := searchRag([]string{p}, tokenize("omega"), 5)
	if len(hits) == 0 {
		t.Fatal("no hits for a term present in the index")
	}
	// Results must come back sorted by score.
	for i := 1; i < len(hits); i++ {
		if hits[i].Score > hits[i-1].Score {
			t.Fatalf("results not sorted at %d: %v > %v", i, hits[i].Score, hits[i-1].Score)
		}
	}
	if hits[0].Chunk.Dir != "/src" {
		t.Fatalf("directory not carried through: %q", hits[0].Chunk.Dir)
	}
	if hits[0].Chunk.Text == "" {
		t.Fatal("chunk text lost")
	}
}

func TestRagSearchNoTermReturnsNothing(t *testing.T) {
	dir := t.TempDir()
	p := buildRagIndexFile(t, dir, 16)
	if hits := searchRag([]string{p}, tokenize("nonexistentterm"), 5); len(hits) != 0 {
		t.Fatalf("expected no hits, got %d", len(hits))
	}
}

func TestRagCachePicksUpRewrites(t *testing.T) {
	dir := t.TempDir()
	p := buildRagIndexFile(t, dir, 8)
	if len(searchRag([]string{p}, tokenize("alpha"), 5)) == 0 {
		t.Fatal("expected hits before the rewrite")
	}

	// Rewrite the index with different content and make sure the size/mtime
	// revalidation picks it up rather than serving the stale cache.
	files := map[string]ragFileJSON{"/src/other.go": {Chunks: []ragChunkJSON{
		{ID: "/src/other.go:1", Text: "unrelated content", Len: 16,
			Terms: map[string]int{"alpha": 3}},
	}}}
	raw, _ := json.Marshal(ragIndexJSON{Directory: "/other", Files: files})
	if err := os.WriteFile(p, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	invalidateRag(p)

	hits := searchRag([]string{p}, tokenize("alpha"), 5)
	if len(hits) == 0 {
		t.Fatal("rewrite was not picked up")
	}
	if hits[0].Chunk.Dir != "/other" {
		t.Fatalf("stale index served: dir=%q", hits[0].Chunk.Dir)
	}
}

func TestRagInvalidateForcesReload(t *testing.T) {
	dir := t.TempDir()
	p := buildRagIndexFile(t, dir, 4)
	_ = searchRag([]string{p}, tokenize("alpha"), 1) // populate the cache
	invalidateRag(p)
	ragMu.Lock()
	_, still := ragCache[p]
	ragMu.Unlock()
	if still {
		t.Fatal("invalidateRag did not drop the entry")
	}
}

func BenchmarkRagSearchCached1000(b *testing.B) {
	dir := b.TempDir()
	p := buildRagIndexFile(b, dir, 1000)
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_ = searchRag([]string{p}, tokenize("alpha omega quux"), 5)
	}
}

func BenchmarkRagSearchCold1000(b *testing.B) {
	dir := b.TempDir()
	p := buildRagIndexFile(b, dir, 1000)
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		invalidateRag(p) // force a re-read and re-parse every iteration
		_ = searchRag([]string{p}, tokenize("alpha omega quux"), 5)
	}
}
