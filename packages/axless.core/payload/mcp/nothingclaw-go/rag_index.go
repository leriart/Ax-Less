// In-memory RAG index.
//
// The original search path re-read and re-parsed every index JSON on every
// query, into map[string]any, and then walked it with type assertions:
//
//	BenchmarkRagSearchUnmarshal500  2.39 ms/op  1.23 MB/op   15,695 allocs/op
//	BenchmarkRagSearchUnmarshal5000 21.5  ms/op 12.41 MB/op  157,163 allocs/op
//
// This file loads each index once into typed structs, keeps a term -> chunk
// postings map so document frequency and scoring only touch chunks that
// actually contain the query term, and revalidates against the file's size and
// modification time so an externally rewritten index is picked up.
package main

import (
	"encoding/json"
	"math"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

type ragChunk struct {
	ID    string
	Text  string
	Terms map[string]int
	Len   int
	Dir   string
}

type ragIndex struct {
	path     string
	modTime  time.Time
	size     int64
	chunks   []ragChunk
	avgDL    float64
	postings map[string][]int32
}

// ---- on-disk shape ----

type ragChunkJSON struct {
	ID    string         `json:"id"`
	Text  string         `json:"text"`
	Len   int            `json:"len"`
	Terms map[string]int `json:"terms"`
}

type ragFileJSON struct {
	Chunks []ragChunkJSON `json:"chunks"`
}

type ragIndexJSON struct {
	Directory string                 `json:"directory"`
	Files     map[string]ragFileJSON `json:"files"`
}

// ---- cache ----

var (
	ragMu    sync.Mutex
	ragCache = map[string]*ragIndex{}
)

const ragCacheMax = 32

// invalidateRag drops a cached index, so a freshly written or deleted index is
// re-read on the next search.
func invalidateRag(path string) {
	ragMu.Lock()
	delete(ragCache, path)
	ragMu.Unlock()
}

func pruneRagLocked() {
	if len(ragCache) <= ragCacheMax {
		return
	}
	oldestPath := ""
	var oldest time.Time
	for p, v := range ragCache {
		if oldestPath == "" || v.modTime.Before(oldest) {
			oldestPath, oldest = p, v.modTime
		}
	}
	if oldestPath != "" {
		delete(ragCache, oldestPath)
	}
}

// loadRagIndex returns the parsed index for path, reusing the cached copy when
// the file has not changed.
func loadRagIndex(path string) *ragIndex {
	ragMu.Lock()
	defer ragMu.Unlock()

	if idx, ok := ragCache[path]; ok {
		if st, err := os.Stat(path); err == nil &&
			st.Size() == idx.size && st.ModTime().Equal(idx.modTime) {
			return idx
		}
		delete(ragCache, path)
	}

	st, err := os.Stat(path)
	if err != nil {
		return nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var raw ragIndexJSON
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil
	}

	idx := &ragIndex{
		path:     path,
		modTime:  st.ModTime(),
		size:     st.Size(),
		postings: make(map[string][]int32),
	}
	// Deterministic file order so a stable index yields stable scores.
	names := make([]string, 0, len(raw.Files))
	for n := range raw.Files {
		names = append(names, n)
	}
	sort.Strings(names)

	sum := 0
	for _, name := range names {
		for _, c := range raw.Files[name].Chunks {
			l := c.Len
			if l == 0 {
				l = len(c.Text)
			}
			if l == 0 {
				l = 1
			}
			sum += l
			ci := int32(len(idx.chunks))
			idx.chunks = append(idx.chunks, ragChunk{
				ID: c.ID, Text: c.Text, Terms: c.Terms, Len: l, Dir: raw.Directory,
			})
			for term := range c.Terms {
				idx.postings[term] = append(idx.postings[term], ci)
			}
		}
	}
	if len(idx.chunks) > 0 {
		idx.avgDL = float64(sum) / float64(len(idx.chunks))
	}

	ragCache[path] = idx
	pruneRagLocked()
	return idx
}

// ragHit is one scored chunk.
type ragHit struct {
	Chunk ragChunk
	Score float64
}

// searchRag scores every cached index against the query terms and returns the
// top results overall.
//
// Only the postings of the query terms are visited, so cost scales with the
// number of chunks that actually mention a term rather than the corpus size.
func searchRag(paths []string, queryTerms []string, topK int) []ragHit {
	seen := map[string]bool{}
	terms := make([]string, 0, len(queryTerms))
	for _, qt := range queryTerms {
		if qt == "" || seen[qt] {
			continue
		}
		seen[qt] = true
		terms = append(terms, qt)
	}

	var hits []ragHit
	for _, p := range paths {
		idx := loadRagIndex(p)
		if idx == nil || len(idx.chunks) == 0 {
			continue
		}
		n := len(idx.chunks)
		scores := make([]float64, n)
		for _, qt := range terms {
			postings := idx.postings[qt]
			df := len(postings)
			if df == 0 {
				continue
			}
			idf := math.Log(1 + (float64(n-df)+0.5)/(float64(df)+0.5))
			for _, ci := range postings {
				i := int(ci)
				tf := idx.chunks[i].Terms[qt]
				if tf == 0 {
					continue
				}
				norm := 1 + math.Log(1+float64(tf))
				avg := idx.avgDL
				if avg <= 0 {
					avg = 1
				}
				dlNorm := 1 / (1 + 0.3*(float64(idx.chunks[i].Len)/avg-1))
				scores[i] += idf * norm * dlNorm
			}
		}
		for i, s := range scores {
			if s > 0 {
				hits = append(hits, ragHit{Chunk: idx.chunks[i], Score: s})
			}
		}
	}
	if len(hits) == 0 {
		return nil
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].Score > hits[j].Score })
	if len(hits) > topK {
		hits = hits[:topK]
	}
	return hits
}

// ragIndexFiles lists the index JSONs under dir, sorted by name.
func ragIndexFiles(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var names []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") {
			names = append(names, dir+string(os.PathSeparator)+e.Name())
		}
	}
	sort.Strings(names)
	return names
}
