//! Structural boundaries belong to the canonical text, not browser geometry.
//! Separators advance highlighting offsets without inserting visible whitespace
//! into preformatted content or invalid children into tables/lists.
use super::markup::Node;

#[derive(Default)]
struct Projection {
    has_text: bool,
    ends_in_newline: bool,
    pending_boundary: bool,
}

pub(super) fn normalize(nodes: Vec<Node>) -> Vec<Node> {
    project(nodes, &mut Projection::default(), false)
}

fn project(nodes: Vec<Node>, projection: &mut Projection, preformatted: bool) -> Vec<Node> {
    let mut output = Vec::new();
    for node in nodes {
        match node {
            Node::Separator => projection.pending_boundary = true,
            Node::Text(value) => {
                if value.is_empty()
                    || (!preformatted
                        && value.trim().is_empty()
                        && (!projection.has_text || projection.pending_boundary))
                {
                    continue;
                }
                if projection.pending_boundary && projection.has_text && !projection.ends_in_newline
                {
                    output.push(Node::Separator);
                }
                projection.pending_boundary = false;
                projection.has_text = true;
                projection.ends_in_newline = value.ends_with('\n');
                output.push(Node::Text(value));
            }
            Node::Element {
                tag,
                attrs,
                children,
            } => {
                let boundary = is_boundary(&tag);
                if boundary {
                    projection.pending_boundary = true;
                }
                let children = project(children, projection, preformatted || tag == "pre");
                output.push(Node::Element {
                    tag,
                    attrs,
                    children,
                });
                if boundary {
                    projection.pending_boundary = true;
                }
            }
        }
    }
    output
}

fn is_boundary(tag: &str) -> bool {
    matches!(
        tag,
        "html"
            | "body"
            | "article"
            | "section"
            | "div"
            | "p"
            | "h1"
            | "h2"
            | "h3"
            | "h4"
            | "h5"
            | "h6"
            | "blockquote"
            | "pre"
            | "ul"
            | "ol"
            | "li"
            | "dl"
            | "dt"
            | "dd"
            | "table"
            | "tr"
            | "th"
            | "td"
            | "caption"
            | "figure"
            | "figcaption"
            | "br"
            | "hr"
    )
}
