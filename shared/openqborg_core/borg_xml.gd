class_name BorgXml
extends RefCounted
## Tiny DOM on top of XMLParser. Nodes are Dictionaries:
## {name: String, attrs: Dictionary, children: Array, text: String}.
## Attribute order is preserved (Dictionaries keep insertion order), which
## matters for writing files the original tools will still accept.


static func parse(text: String) -> Dictionary:
	var parser := XMLParser.new()
	if parser.open_buffer(text.to_utf8_buffer()) != OK:
		return {}
	var stack: Array = []
	var root := {}
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var node := {"name": parser.get_node_name(), "attrs": {}, "children": [], "text": ""}
				for i in parser.get_attribute_count():
					node.attrs[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
				if stack.is_empty():
					root = node
				else:
					stack.back().children.append(node)
				if not parser.is_empty():
					stack.append(node)
			XMLParser.NODE_ELEMENT_END:
				if not stack.is_empty():
					stack.pop_back()
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if not stack.is_empty():
					stack.back().text += parser.get_node_data()
	return root


static func write_node(node: Dictionary) -> String:
	var attrs := ""
	for key in node.attrs:
		attrs += ' %s="%s"' % [key, escape(str(node.attrs[key]))]
	if node.children.is_empty() and node.text.is_empty():
		return "<%s%s/>" % [node.name, attrs]
	var inner: String = escape(node.text)
	for child in node.children:
		inner += write_node(child)
	return "<%s%s>%s</%s>" % [node.name, attrs, inner, node.name]


static func escape(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
