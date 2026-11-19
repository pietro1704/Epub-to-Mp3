//! A deliberately small CSS language: unsupported syntax loses styling, never text.
//! Escapes, at-rules, URL-bearing functions and arbitrary selectors are not admitted.
use super::{bounded, Result, MAX_CSS_BYTES};

pub(super) fn stylesheet(source: &str) -> Result<String> {
    bounded(source.len(), MAX_CSS_BYTES, "CSS bytes")?;
    let source = without_comments(source);
    let mut output = String::new();
    let mut count = 0;
    for block in source.split('}') {
        let Some((selector, declarations)) = block.split_once('{') else {
            continue;
        };
        let selector = selector.trim();
        if selector.is_empty()
            || selector.len() > 2048
            || !selector.chars().all(|c| {
                c.is_ascii_alphanumeric()
                    || matches!(
                        c,
                        ' ' | '\n' | '\t' | '.' | '#' | '-' | '_' | '>' | '+' | '~' | ',' | '*'
                    )
            })
        {
            continue;
        }
        let declarations = inline(declarations);
        if declarations.is_empty() {
            continue;
        }
        count += 1;
        bounded(count, 2048, "CSS rules")?;
        output.push_str(&root_selectors(selector));
        output.push_str(" { ");
        output.push_str(&declarations);
        output.push_str(" }\n");
    }
    Ok(output)
}

fn root_selectors(selector: &str) -> String {
    let mut output = String::new();
    let mut cursor = 0;
    let bytes = selector.as_bytes();
    while cursor < bytes.len() {
        let start = cursor;
        if bytes[cursor].is_ascii_alphabetic() || matches!(bytes[cursor], b'-' | b'_') {
            cursor += 1;
            while cursor < bytes.len()
                && (bytes[cursor].is_ascii_alphanumeric() || matches!(bytes[cursor], b'-' | b'_'))
            {
                cursor += 1;
            }
            let token = &selector[start..cursor];
            let qualified = start > 0 && matches!(bytes[start - 1], b'.' | b'#');
            if !qualified
                && (token.eq_ignore_ascii_case("html") || token.eq_ignore_ascii_case("body"))
            {
                output.push_str(".reader-root-");
                output.push_str(&token.to_ascii_lowercase());
            } else {
                output.push_str(token);
            }
        } else {
            output.push(char::from(bytes[cursor]));
            cursor += 1;
        }
    }
    output
}

pub(super) fn inline(source: &str) -> String {
    let source = without_comments(source);
    let mut output = Vec::new();
    for declaration in source.split(';') {
        let Some((property, value)) = declaration.split_once(':') else {
            continue;
        };
        let property = property.trim().to_ascii_lowercase();
        let value = value.trim();
        if !allowed_property(&property) || !safe_value(value) {
            continue;
        }
        let lower = value.to_ascii_lowercase();
        let permitted = match property.as_str() {
            "font-size" => safe_font_size(&lower),
            "line-height" => {
                lower.parse::<f64>().is_ok_and(|n| (1.0..=3.0).contains(&n))
                    || matches!(lower.as_str(), "normal" | "inherit")
            }
            "font-weight" => matches!(
                lower.as_str(),
                "normal"
                    | "bold"
                    | "bolder"
                    | "lighter"
                    | "inherit"
                    | "100"
                    | "200"
                    | "300"
                    | "400"
                    | "500"
                    | "600"
                    | "700"
                    | "800"
                    | "900"
            ),
            "text-align" => matches!(
                lower.as_str(),
                "start" | "end" | "left" | "right" | "center" | "justify" | "inherit"
            ),
            "white-space" => matches!(
                lower.as_str(),
                "normal" | "pre-wrap" | "pre-line" | "break-spaces" | "inherit"
            ),
            _ => true,
        };
        if permitted {
            output.push(format!("{property}: {value}"));
        }
    }
    output.join("; ")
}

fn allowed_property(property: &str) -> bool {
    matches!(
        property,
        "font-family"
            | "font-size"
            | "font-style"
            | "font-variant"
            | "font-weight"
            | "line-height"
            | "letter-spacing"
            | "word-spacing"
            | "text-align"
            | "text-decoration"
            | "text-indent"
            | "text-transform"
            | "vertical-align"
            | "white-space"
            | "color"
            | "background-color"
            | "border"
            | "border-color"
            | "border-style"
            | "border-width"
            | "border-collapse"
            | "border-spacing"
            | "border-radius"
            | "margin"
            | "margin-top"
            | "margin-bottom"
            | "margin-left"
            | "margin-right"
            | "padding"
            | "padding-top"
            | "padding-bottom"
            | "padding-left"
            | "padding-right"
    )
}

fn safe_value(value: &str) -> bool {
    if value.is_empty() || value.len() > 512 {
        return false;
    }
    // No CSS escape or custom-property/function indirection can conceal a URL.
    if value.contains('(') {
        let Some((function, rest)) = value.split_once('(') else {
            return false;
        };
        if !matches!(
            function.to_ascii_lowercase().as_str(),
            "rgb" | "rgba" | "hsl" | "hsla"
        ) {
            return false;
        }
        let Some(arguments) = rest.strip_suffix(')') else {
            return false;
        };
        return arguments
            .chars()
            .all(|c| c.is_ascii_digit() || matches!(c, ' ' | ',' | '.' | '%' | '-' | '+'));
    }
    value.chars().all(|c| {
        c.is_ascii_alphanumeric()
            || matches!(c, ' ' | '.' | '#' | '%' | '-' | '_' | ',' | '\'' | '"')
    }) && !value
        .split(|c: char| !c.is_ascii_digit() && c != '.')
        .any(|number| !number.is_empty() && number.parse::<f64>().is_ok_and(|value| value > 1000.0))
}

fn safe_font_size(value: &str) -> bool {
    if matches!(
        value,
        "inherit" | "small" | "medium" | "large" | "x-large" | "xx-large" | "larger" | "smaller"
    ) {
        return true;
    }
    for (unit, min, max) in [
        ("rem", 0.5, 5.0),
        ("em", 0.5, 5.0),
        ("px", 8.0, 80.0),
        ("pt", 6.0, 60.0),
        ("%", 50.0, 500.0),
    ] {
        if let Some(number) = value.strip_suffix(unit) {
            return number
                .parse::<f64>()
                .is_ok_and(|n| (min..=max).contains(&n));
        }
    }
    false
}

fn without_comments(source: &str) -> String {
    let mut remaining = source;
    let mut output = String::with_capacity(source.len());
    while let Some(start) = remaining.find("/*") {
        output.push_str(&remaining[..start]);
        let Some(end) = remaining[start + 2..].find("*/") else {
            return output;
        };
        remaining = &remaining[start + 2 + end + 2..];
    }
    output.push_str(remaining);
    output
}
