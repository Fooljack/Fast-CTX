//! Sixteen-byte paged hexadecimal view for any regular file.

use super::DEFAULT_HEX_LINE_LIMIT;
use crate::budget::TokenBudget;
use crate::model::ToolResponse;
use crate::paths::io_error_message;
use crate::render_plan::{LineRenderGraph, RenderPlanError};
use std::fmt::Write as _;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::Arc;

const BYTES_PER_LINE: u64 = 16;
const HEX_COLUMN_WIDTH: usize = 48;

pub(super) fn read_hex_file(
    path: &Path,
    offset: Option<usize>,
    limit: Option<usize>,
    budget: TokenBudget,
) -> ToolResponse {
    let offset = offset.unwrap_or(1);
    let limit = limit.unwrap_or(DEFAULT_HEX_LINE_LIMIT);
    if offset == 0 {
        return ToolResponse::error("Invalid offset value: 0. Expected an integer >= 1.");
    }
    if limit == 0 {
        return ToolResponse::error("Invalid limit value: 0. Expected an integer >= 1.");
    }

    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) => return ToolResponse::error(io_error_message(path, &error)),
    };
    let file_size = match file.metadata() {
        Ok(metadata) => metadata.len(),
        Err(error) => return ToolResponse::error(io_error_message(path, &error)),
    };
    if file_size == 0 {
        return ToolResponse::text("Warning: the file exists but is empty.");
    }
    let total_lines = file_size / BYTES_PER_LINE + u64::from(file_size % BYTES_PER_LINE != 0);
    let offset_line = offset as u64;
    if offset_line > total_lines {
        let noun = if total_lines == 1 { "line" } else { "lines" };
        return ToolResponse::text(format!(
            "Warning: the file has only {total_lines} {noun}, but offset={offset} was requested."
        ));
    }

    let byte_offset = (offset_line - 1) * BYTES_PER_LINE;
    if let Err(error) = file.seek(SeekFrom::Start(byte_offset)) {
        return ToolResponse::error(io_error_message(path, &error));
    }
    let remaining = total_lines - offset_line + 1;
    let budget_probe = budget.value.saturating_mul(4).saturating_add(1) as u64;
    let candidate_lines = remaining.min(limit as u64).min(budget_probe.max(1));
    let mut rendered = Vec::with_capacity(candidate_lines.min(usize::MAX as u64) as usize);
    for line_index in 0..candidate_lines {
        let mut bytes = [0_u8; BYTES_PER_LINE as usize];
        let mut read = 0_usize;
        while read < bytes.len() {
            match file.read(&mut bytes[read..]) {
                Ok(0) => break,
                Ok(count) => read += count,
                Err(error) => return ToolResponse::error(io_error_message(path, &error)),
            }
        }
        if read == 0 {
            break;
        }
        rendered.push(format_hex_line(
            byte_offset + line_index * BYTES_PER_LINE,
            &bytes[..read],
        ));
    }

    render_hex_page(rendered, offset_line, total_lines, budget)
}

struct SelectedHexPage {
    shown: usize,
    terminal: String,
    tokens: usize,
}

fn render_hex_page(
    rendered: Vec<String>,
    offset_line: u64,
    total_lines: u64,
    budget: TokenBudget,
) -> ToolResponse {
    let maximum = rendered.len();
    let lines = rendered.into_iter().map(Arc::<str>::from).collect();
    let mut graph = match LineRenderGraph::new(lines, None) {
        Ok(graph) => graph,
        Err(error) => return render_failure(error),
    };
    let selected =
        match select_hex_prefix(&mut graph, maximum, offset_line, total_lines, budget.value) {
            Ok(Some(selected)) => selected,
            Ok(None) => return budget_too_small(budget),
            Err(error) => return render_failure(error),
        };
    let SelectedHexPage {
        shown,
        terminal,
        tokens,
    } = selected;
    let notes = [terminal];
    match graph.finish(shown, &notes, tokens, budget.value, None) {
        Ok(rendered) => ToolResponse::text(rendered.text),
        Err(error) => render_failure(error),
    }
}

fn select_hex_prefix(
    graph: &mut LineRenderGraph,
    maximum: usize,
    offset_line: u64,
    total_lines: u64,
    budget: usize,
) -> Result<Option<SelectedHexPage>, RenderPlanError> {
    for shown in (1..=maximum).rev() {
        let last = offset_line + shown as u64 - 1;
        let terminal = hex_terminal(offset_line, last, total_lines);
        let notes = [&terminal];
        let tokens = graph.probe_notes(shown, &notes, None)?;
        if tokens <= budget {
            return Ok(Some(SelectedHexPage {
                shown,
                terminal,
                tokens,
            }));
        }
    }
    Ok(None)
}

fn hex_terminal(first: u64, last: u64, total_lines: u64) -> String {
    if last < total_lines {
        format!(
            "(Partial: {} of {total_lines} shown. Continue with offset={}.)",
            line_span(first, last),
            last + 1
        )
    } else {
        format!(
            "(Complete: reached end of file; {} of {total_lines} shown.)",
            line_span(first, last)
        )
    }
}

fn render_failure(error: RenderPlanError) -> ToolResponse {
    ToolResponse::error(format!("Internal hex rendering failure: {error}"))
}

fn budget_too_small(budget: TokenBudget) -> ToolResponse {
    ToolResponse::error(format!(
        "{}={} is too small to return the required continuation note. Increase it and retry.",
        budget.variable, budget.value
    ))
}

fn format_hex_line(offset: u64, bytes: &[u8]) -> String {
    let mut hex_column = String::with_capacity(HEX_COLUMN_WIDTH);
    for index in 0..BYTES_PER_LINE as usize {
        if index > 0 {
            hex_column.push(' ');
        }
        if index == 8 {
            hex_column.push(' ');
        }
        if let Some(byte) = bytes.get(index) {
            let _ = write!(hex_column, "{byte:02x}");
        } else {
            hex_column.push_str("  ");
        }
    }
    debug_assert_eq!(hex_column.len(), HEX_COLUMN_WIDTH);
    let ascii = bytes
        .iter()
        .map(|byte| {
            if (0x20..=0x7E).contains(byte) {
                char::from(*byte)
            } else {
                '.'
            }
        })
        .collect::<String>();
    format!("{offset:08x}  {hex_column}  |{ascii}|")
}

fn line_span(first: u64, last: u64) -> String {
    if first == last {
        format!("line {first}")
    } else {
        format!("lines {first}-{last}")
    }
}

#[cfg(test)]
mod tests {
    use super::{format_hex_line, hex_terminal, read_hex_file, select_hex_prefix};
    use crate::ToolContent;
    use crate::budget::{TokenBudget, assemble_text, estimate_tokens};
    use crate::render_plan::LineRenderGraph;
    use std::sync::Arc;

    #[test]
    fn full_and_partial_lines_keep_the_ascii_column_aligned() {
        assert_eq!(
            format_hex_line(0, b"0123456789ABCDEF"),
            "00000000  30 31 32 33 34 35 36 37  38 39 41 42 43 44 45 46  |0123456789ABCDEF|"
        );
        assert_eq!(
            format_hex_line(16, &[0x20, 0x7E, 0x1F, 0x7F]),
            "00000010  20 7e 1f 7f                                       | ~..|"
        );
        assert_eq!(
            format_hex_line(0x1_0000_0000, b"x"),
            "100000000  78                                                |x|"
        );
    }

    #[test]
    fn token_budget_never_returns_an_unusable_success() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("bytes.bin");
        std::fs::write(&path, b"0123456789ABCDEFmore").unwrap();
        let response = read_hex_file(
            &path,
            None,
            None,
            TokenBudget {
                value: 1,
                variable: "FASTCTX_READ_TOKEN_BUDGET",
            },
        );
        assert!(response.is_error);
        assert_eq!(
            response.content,
            vec![ToolContent::Text(
                "FASTCTX_READ_TOKEN_BUDGET=1 is too small to return the required continuation note. Increase it and retry."
                    .to_string()
            )]
        );
    }

    #[test]
    fn prefix_checkpoints_preserve_the_previous_budget_selection() {
        let lines = (0..128)
            .map(|index| format_hex_line(index * 16, b"0123456789ABCDEF"))
            .collect::<Vec<_>>();

        for (offset_line, total_lines) in [(1_u64, 129_u64), (9_999, 10_126)] {
            for budget in [1_usize, 50, 100, 500, 1_000, 8_500] {
                let expected = (1..=lines.len()).rev().find_map(|shown| {
                    let last = offset_line + shown as u64 - 1;
                    let terminal = hex_terminal(offset_line, last, total_lines);
                    let output = assemble_text(&lines[..shown], std::slice::from_ref(&terminal));
                    (estimate_tokens(&output) <= budget).then_some((shown, terminal))
                });
                let mut graph = LineRenderGraph::new(
                    lines.iter().cloned().map(Arc::<str>::from).collect(),
                    None,
                )
                .unwrap();
                let selected =
                    select_hex_prefix(&mut graph, lines.len(), offset_line, total_lines, budget)
                        .unwrap()
                        .map(|selected| (selected.shown, selected.terminal));
                assert_eq!(selected, expected, "offset={offset_line}, budget={budget}");
            }
        }
    }

    #[test]
    fn dense_hex_rendering_builds_one_linear_prefix_graph() {
        let count = 20_000_usize;
        let lines = (0..count)
            .map(|index| Arc::<str>::from(format_hex_line(index as u64 * 16, b"0123456789ABCDEF")))
            .collect::<Vec<_>>();
        let expected_bytes = lines.iter().map(|line| line.len()).sum::<usize>();
        let mut graph = LineRenderGraph::new(lines, None).unwrap();
        let selected = select_hex_prefix(&mut graph, count, 1, count as u64 + 1, 1_000)
            .unwrap()
            .unwrap();
        let notes = [selected.terminal];
        let rendered = graph
            .finish(selected.shown, &notes, selected.tokens, 1_000, None)
            .unwrap();
        assert!(estimate_tokens(&rendered.text) <= 1_000);

        let metrics = graph.metrics();
        assert_eq!(metrics.render_units_built, count);
        assert_eq!(metrics.render_bytes_built, expected_bytes);
        assert_eq!(metrics.full_tokenizer_calls, 1);
        assert!(metrics.token_prefix_appends <= count.saturating_mul(2));
        assert!(metrics.token_suffix_probes <= count);
    }
}
