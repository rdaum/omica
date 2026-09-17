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
	text, is_cdata, end, ok := dom_xml_element_text(STREAM_DOC, label)
	testing.expect(t, ok)
	testing.expect(t, !is_cdata)
	testing.expect_value(t, text, "A &amp; B")
	testing.expect_value(t, dom_xml_decode_entities_into(text, context.temp_allocator), "A & B")

	comment, comment_ok := dom_xml_next_tag(STREAM_DOC, end)
	testing.expect(t, comment_ok)
	testing.expect_value(t, comment.name, "rdfs:comment")
	ctext, c_cdata, cend, c_ok := dom_xml_element_text(STREAM_DOC, comment)
	testing.expect(t, c_ok)
	testing.expect(t, c_cdata, "comment body is CDATA")
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
	_, _, _, text_ok := dom_xml_element_text(doc, tag)
	testing.expect(t, !text_ok)
}
