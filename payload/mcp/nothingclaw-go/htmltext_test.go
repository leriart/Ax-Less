// Equivalence tests for the single-pass HTML->text converter. These pin the
// behaviour the old 33-regex implementation produced, so the rewrite cannot
// silently change what fetch_url returns to the model.
package main

import (
	"strings"
	"testing"
)

func TestHtmlToTextTitleAndBody(t *testing.T) {
	html := `<!DOCTYPE html><html><head><title>Hello   World</title>` +
		`<style>body{color:red}</style><script>var x="<b>not markup</b>";</script></head>` +
		`<body><h1>Heading</h1><p>First para.</p><p>Second para with <a href="#">a link</a>.</p>` +
		`<ul><li>one</li><li>two</li></ul><!-- a comment --><pre>code   here</pre></body></html>`

	title, text := htmlToText(html)
	if title != "Hello World" {
		t.Errorf("title = %q", title)
	}
	for _, want := range []string{"Heading", "First para.", "Second para with a link.", "one", "two", "code here"} {
		if !strings.Contains(text, want) {
			t.Errorf("text missing %q\ngot:\n%s", want, text)
		}
	}
	for _, unwanted := range []string{"color:red", "var x", "not markup", "a comment", "<", ">"} {
		if strings.Contains(text, unwanted) {
			t.Errorf("text should not contain %q\ngot:\n%s", unwanted, text)
		}
	}
	// Block tags must have become newlines, not run-ons.
	if !strings.Contains(text, "First para.\nSecond para") {
		t.Errorf("paragraphs not separated:\n%s", text)
	}
}

func TestHtmlToTextEntitiesAndBareLt(t *testing.T) {
	_, text := htmlToText(`<p>5 &lt; 7 &amp;&amp; 9 &gt; 3</p>`)
	if !strings.Contains(text, "5 < 7 && 9 > 3") {
		t.Errorf("entities not decoded: %q", text)
	}

	// A '<' that does not begin a tag must survive as text.
	_, text = htmlToText(`<p>if a < b and c > d</p>`)
	if !strings.Contains(text, "if a < b and c > d") {
		t.Errorf("bare '<' mangled: %q", text)
	}
}

func TestHtmlToTextSkipsNestedAndUnclosedSkipTags(t *testing.T) {
	_, text := htmlToText(`<div>a<iframe>hidden</iframe>b</div>`)
	if strings.Contains(text, "hidden") {
		t.Errorf("iframe content not dropped: %q", text)
	}
	if !strings.Contains(text, "a") || !strings.Contains(text, "b") {
		t.Errorf("surrounding text lost: %q", text)
	}

	// No closing tag: everything after it is dropped, like the old `.*?</tag>`.
	_, text = htmlToText(`<div>a</div><script>never closed`)
	if strings.Contains(text, "never closed") {
		t.Errorf("unclosed script content not dropped: %q", text)
	}
}

func TestHtmlToTextAttributeWithAngleBracket(t *testing.T) {
	// A '>' inside a quoted attribute must not terminate the tag early.
	_, text := htmlToText(`<p title="a > b">visible</p><style>x{y:1}</style>`)
	if !strings.Contains(text, "visible") {
		t.Errorf("tag ended early on quoted '>': %q", text)
	}
	if strings.Contains(text, "y:1") {
		t.Errorf("style not dropped: %q", text)
	}
}

func TestHtmlToTextEmpty(t *testing.T) {
	title, text := htmlToText("")
	if title != "" || text != "" {
		t.Errorf("empty input gave %q / %q", title, text)
	}
}

func BenchmarkHtmlToText(b *testing.B) {
	var sb strings.Builder
	for i := 0; i < 200; i++ {
		sb.WriteString(`<div class="row"><h2>Section `)
		sb.WriteString(strings.Repeat("x", 20))
		sb.WriteString(`</h2><p>Paragraph body text with <a href="/x">a link</a> and <em>emphasis</em>.</p>`)
		sb.WriteString(`<script>var ignored = 1;</script></div>`)
	}
	doc := sb.String()
	b.SetBytes(int64(len(doc)))
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		_, _ = htmlToText(doc)
	}
}
