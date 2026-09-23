package dom

import "core:testing"

@(private)
STREAM_DOC :: `<?xml version="1.0"?>
<rdf:RDF>
<!-- a comment with <tags> inside -->
<owl:Ontology rdf:about="http://example.org/"/>
<owl:Class rdf:about="http://example.org/A">
  <rdf:type rdf:resource="http://www.w3.org/2002/07/owl#Class"/>
  <rdfs:label xml:lang="en">A &amp; B</rdfs:label>
  <rdfs:comment><![CDATA[Has <a href="x">markup</a> & a bare <br> tag.]]></rdfs:comment>
  <owl:equivalentClass><owl:Restriction><owl:onProperty rdf:resource="p"/></owl:Restriction></owl:equivalentClass>
</owl:Class>
</rdf:RDF>
`

@(test)
test_dom_xml_next_tag_sequence :: proc(t: ^testing.T) {
	kinds: [dynamic]Dom_Xml_Tag_Kind
	names: [dynamic]string
	defer delete(kinds)
	defer delete(names)
	pos := 0
	for {
		tag, ok := dom_xml_next_tag(STREAM_DOC, pos)
		if !ok {
			break
		}
		pos = tag.end
		append(&kinds, tag.kind)
		append(&names, tag.name)
	}
	// The declaration and the comment never surface; the comment's inner
	// <tags> are not tags.
	expected_names := []string {
		"rdf:RDF", "owl:Ontology", "owl:Class", "rdf:type", "rdfs:label", "",
		"rdfs:comment", "", "owl:equivalentClass", "owl:Restriction", "owl:onProperty", "", "", "", "",
	}
	testing.expect_value(t, len(names), len(expected_names))
	for name, i in expected_names {
		if i < len(names) {
			testing.expect_value(t, names[i], name)
		}
	}
	testing.expect_value(t, kinds[1], Dom_Xml_Tag_Kind.Self_Close)
	testing.expect_value(t, kinds[2], Dom_Xml_Tag_Kind.Open)
	testing.expect_value(t, kinds[5], Dom_Xml_Tag_Kind.Close)
}

@(test)
test_dom_xml_attr_value :: proc(t: ^testing.T) {
	head := `<owl:Class rdf:about="http://example.org/A" xml:lang="en">`
	about, ok := dom_xml_attr_value(head, "rdf:about")
	testing.expect(t, ok)
	testing.expect_value(t, about, "http://example.org/A")
	lang, lang_ok := dom_xml_attr_value(head, "lang")
	testing.expect(t, !lang_ok, "lang must not match inside xml:lang")
	_ = lang
	_, missing := dom_xml_attr_value(head, "rdf:resource")
	testing.expect(t, !missing)
}

@(test)
test_dom_xml_element_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Position on <rdfs:label>.
	pos := 0
	label: Dom_Xml_Tag
	for {
		tag, ok := dom_xml_next_tag(STREAM_DOC, pos)
		testing.expect(t, ok)
		pos = tag.end
		if tag.name == "rdfs:label" {
			label = tag
			break
		}
	}
	text, end, ok := dom_xml_element_text(STREAM_DOC, label, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, text, "A & B")

	comment, comment_ok := dom_xml_next_tag(STREAM_DOC, end)
	testing.expect(t, comment_ok)
	testing.expect_value(t, comment.name, "rdfs:comment")
	ctext, cend, c_ok := dom_xml_element_text(STREAM_DOC, comment, context.temp_allocator)
	testing.expect(t, c_ok)
	testing.expect_value(t, ctext, `Has <a href="x">markup</a> & a bare <br> tag.`)

	// Nested elements are skipped as a unit.
	equiv, equiv_ok := dom_xml_next_tag(STREAM_DOC, cend)
	testing.expect(t, equiv_ok)
	testing.expect_value(t, equiv.name, "owl:equivalentClass")
	after, skip_ok := dom_xml_skip_element(STREAM_DOC, equiv)
	testing.expect(t, skip_ok)
	closing, closing_ok := dom_xml_next_tag(STREAM_DOC, after)
	testing.expect(t, closing_ok)
	testing.expect_value(t, closing.kind, Dom_Xml_Tag_Kind.Close)
	testing.expect_value(t, closing.head, "</owl:Class>")
}

@(test)
test_dom_xml_element_text_unterminated :: proc(t: ^testing.T) {
	doc := `<a><b>never closed`
	tag, ok := dom_xml_next_tag(doc, 0)
	testing.expect(t, ok)
	_, _, text_ok := dom_xml_element_text(doc, tag, context.temp_allocator)
	testing.expect(t, !text_ok)
	_, skip_ok := dom_xml_skip_element(doc, tag)
	testing.expect(t, !skip_ok)
	free_all(context.temp_allocator)
}

// Text content of the first element in doc, and whether the scan ended just
// past the document's final close tag.
@(private)
stream_text_of :: proc(doc: string) -> (text: string, at_end: bool, ok: bool) {
	tag, tag_ok := dom_xml_next_tag(doc, 0)
	if !tag_ok {
		return "", false, false
	}
	end: int
	text, end, ok = dom_xml_element_text(doc, tag, context.temp_allocator)
	return text, end == len(doc), ok
}

@(test)
test_dom_xml_element_text_mixed_content :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		doc:      string,
		expected: string,
	}
	cases := []Case {
		// CDATA need not be flush against the open tag.
		{"<c>\n    <![CDATA[A <b>bold</b> thing & more]]>\n  </c>", "\n    A <b>bold</b> thing & more\n  "},
		// Text on both sides of a CDATA section; only the plain text decodes.
		{"<c>x &amp; <![CDATA[&amp;]]> y</c>", "x & &amp; y"},
		// Comments and processing instructions are not content.
		{"<c>A<!--x-->B<?pi data?>C</c>", "ABC"},
		// Nested element text is included in order; markup is not.
		{"<c>one <b>two <i>three</i></b> four</c>", "one two three four"},
		// A CDATA close inside a comment is not a CDATA close.
		{"<c><!-- ]]> --><![CDATA[<x>]]></c>", "<x>"},
		{"<c/>", ""},
		{"<c></c>", ""},
	}
	for c in cases {
		text, at_end, ok := stream_text_of(c.doc)
		testing.expectf(t, ok, "%q: not ok", c.doc)
		testing.expectf(t, at_end, "%q: end is not past the close tag", c.doc)
		testing.expect_value(t, text, c.expected)
	}
}

@(test)
test_dom_xml_element_text_plain_is_a_slice :: proc(t: ^testing.T) {
	doc := "<c>plain text</c>"
	tag, _ := dom_xml_next_tag(doc, 0)
	text, _, ok := dom_xml_element_text(doc, tag, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, raw_data(text), raw_data(doc[3:]))
}

@(test)
test_dom_xml_element_text_unterminated_markup :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for doc in ([]string{"<c><![CDATA[never closed</c>", "<c>a<!-- never closed</c>"}) {
		_, _, ok := stream_text_of(doc)
		testing.expectf(t, !ok, "%q: expected failure", doc)
	}
}
