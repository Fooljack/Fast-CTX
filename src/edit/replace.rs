//! Two-pass batch replacement with full blast-radius counting and per-file CAS commits.

use super::document::TextDocument;
use super::locks::{FilePathLock, PathIdentity};
use super::{ReplaceRequest, ReplaceService, edit_token_budget, plural};
use crate::budget::{
    ExactPrefixCounter, GLOBAL_TOKEN_BUDGET_ENV, assemble_text, estimate_tokens,
    tool_token_budget_for_required,
};
use crate::model::ToolResponse;
use globset::{Glob, GlobSet, GlobSetBuilder};
use regex::{Regex, RegexBuilder};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

const MAX_CANDIDATES: usize = 10_000;
const MAX_STORED_PREVIEWS: usize = 100_000;

#[derive(Debug)]
struct AnalyzedFile {
    path: String,
    name_identity: PathIdentity,
    identity: PathIdentity,
    revision: String,
    matches: usize,
    previews: Vec<String>,
    previews_truncated: bool,
    used_fallback: bool,
}

#[derive(Debug)]
struct Issue {
    path: String,
    message: String,
}

#[derive(Debug)]
struct ReportGroup {
    lines: Vec<String>,
}

pub(super) fn replace(
    editor: &ReplaceService,
    request: ReplaceRequest,
    max_file_size_mib: u64,
) -> ToolResponse {
    let budget = match edit_token_budget() {
        Ok(budget) => budget,
        Err(error) => return ToolResponse::error(error),
    };
    if request.path.is_empty() {
        return ToolResponse::error(
            "The path parameter is required. Give the absolute file or directory to edit.",
        );
    }
    let root = match resolve_root(&request.path) {
        Ok(root) => root,
        Err(error) => return ToolResponse::error(error),
    };
    let single_file = root.is_file();
    if single_file && request.fallback_encoding.is_some() {
        return ToolResponse::error(
            "The fallback_encoding parameter only applies to directory targets; use encoding for a single file.",
        );
    }
    if !single_file && request.encoding.is_some() {
        return ToolResponse::error(
            "The encoding parameter only applies to single-file targets; use fallback_encoding for a directory.",
        );
    }
    if let Some(encoding) = request.encoding.as_deref()
        && let Err(rejection) = crate::encoding::canonical_encoding_label(encoding)
    {
        return ToolResponse::error(rejection.message(&crate::paths::display_path(&root)));
    }
    if let Some(encoding) = request.fallback_encoding.as_deref()
        && let Err(rejection) = crate::encoding::canonical_encoding_label(encoding)
    {
        return ToolResponse::error(rejection.message(&crate::paths::display_path(&root)));
    }
    let compiled = match build_regex(&request) {
        Ok(compiled) => compiled,
        Err(error) => return ToolResponse::error(error),
    };
    if compiled.can_match_empty && request.max_replacements.is_none() {
        return ToolResponse::error(
            "This pattern can match empty (zero-width) and would insert at every position. Set max_replacements to cap the blast radius, then retry.",
        );
    }
    if let Err(error) = validate_replacement_references(&compiled.regex, &request.replacement) {
        return ToolResponse::error(error);
    }
    let regex = compiled.regex;
    let glob = match build_glob(request.glob.as_deref()) {
        Ok(glob) => glob,
        Err(error) => return ToolResponse::error(error),
    };
    let candidates = match crate::traversal::collect_project_candidates(&root, glob.as_ref(), None)
    {
        Ok(candidates) => candidates,
        Err(error) => return ToolResponse::error(error),
    };
    if candidates.len() > MAX_CANDIDATES {
        return ToolResponse::error(
            "Too many candidate files: over 10000 matched. Narrow the path or glob.",
        );
    }

    let dry_run = request.dry_run.unwrap_or(false);
    let mut analyzed = Vec::new();
    let mut skipped = Vec::new();
    let mut planning_failures = Vec::new();
    let mut seen_identities = BTreeMap::new();
    let mut total_matches = 0_usize;
    let mut preview_slots = preview_slot_limit(dry_run, budget);
    for candidate in candidates {
        let opened = open_candidate(
            &candidate.display,
            request.encoding.as_deref(),
            request.fallback_encoding.as_deref(),
            max_file_size_mib,
        );
        let (document, used_fallback) = match opened {
            Ok(opened) => opened,
            Err(error) if is_binary_error(&error) => {
                if single_file {
                    return ToolResponse::error(error);
                }
                skipped.push(Issue {
                    path: candidate.display,
                    message: "binary file".to_string(),
                });
                continue;
            }
            Err(error) if is_skippable_error(&error) => {
                if single_file {
                    return ToolResponse::error(error);
                }
                skipped.push(Issue {
                    path: candidate.display,
                    message: short_issue(&error),
                });
                continue;
            }
            Err(error) => {
                if single_file {
                    return ToolResponse::error(error);
                }
                planning_failures.push(Issue {
                    path: candidate.display,
                    message: error,
                });
                continue;
            }
        };
        let name_identity = match PathIdentity::for_name(document.target_path()) {
            Ok(identity) => identity,
            Err(error) => {
                if single_file {
                    return ToolResponse::error(error);
                }
                planning_failures.push(Issue {
                    path: candidate.display,
                    message: error,
                });
                continue;
            }
        };
        let identity = match PathIdentity::for_existing(document.target_path()) {
            Ok(identity) => identity,
            Err(error) => {
                if single_file {
                    return ToolResponse::error(error);
                }
                planning_failures.push(Issue {
                    path: candidate.display,
                    message: error,
                });
                continue;
            }
        };
        if seen_identities
            .insert(identity.clone(), document.display_path())
            .is_some()
        {
            continue;
        }
        let analysis = analyze_file(&document, &regex, &request.replacement, preview_slots);
        preview_slots = preview_slots.saturating_sub(analysis.previews.len());
        total_matches = total_matches.saturating_add(analysis.matches);
        if analysis.matches == 0 {
            continue;
        }
        if let Err(message) =
            validate_replacement(&document, &regex, &request.replacement, max_file_size_mib)
        {
            if single_file {
                return ToolResponse::error(message);
            }
            planning_failures.push(Issue {
                path: document.display_path(),
                message,
            });
            continue;
        }
        analyzed.push(AnalyzedFile {
            path: document.display_path(),
            name_identity,
            identity,
            revision: document.revision(),
            matches: analysis.matches,
            previews_truncated: analysis.matches > analysis.previews.len(),
            previews: analysis.previews,
            used_fallback,
        });
    }

    if let Some(maximum) = request.max_replacements
        && total_matches > maximum
    {
        return ToolResponse::error(format!(
            "Refusing to write: {total_matches} matches exceed max_replacements={maximum}. Raise the cap or narrow the pattern; nothing was written."
        ));
    }

    let fallback_label = request
        .fallback_encoding
        .as_deref()
        .and_then(|value| crate::encoding::canonical_encoding_label(value).ok());
    if dry_run {
        return format_dry_run(
            &analyzed,
            &skipped,
            &planning_failures,
            total_matches,
            budget,
            fallback_label,
        );
    }

    let mut successes = Vec::new();
    let mut failures = planning_failures;
    let mut written_replacements = 0_usize;
    let mut ordered = analyzed.iter().enumerate().collect::<Vec<_>>();
    ordered.sort_by(|(_, left), (_, right)| {
        left.identity
            .cmp(&right.identity)
            .then_with(|| left.path.as_bytes().cmp(right.path.as_bytes()))
    });
    for (original_index, file) in ordered {
        let path = Path::new(&file.path);
        let name_process_lock = editor.path_locks.for_identity(&file.name_identity);
        let _name_process_guard = name_process_lock.lock().unwrap();
        let _name_file_guard = match FilePathLock::acquire(&file.name_identity, path) {
            Ok(guard) => guard,
            Err(error) => {
                failures.push(Issue {
                    path: file.path.clone(),
                    message: error,
                });
                continue;
            }
        };
        let target_process_lock = editor.path_locks.for_identity(&file.identity);
        let _target_process_guard = target_process_lock.lock().unwrap();
        let _target_file_guard = match FilePathLock::acquire(&file.identity, path) {
            Ok(guard) => guard,
            Err(error) => {
                failures.push(Issue {
                    path: file.path.clone(),
                    message: error,
                });
                continue;
            }
        };
        let document = match TextDocument::open(
            &file.path,
            if single_file {
                request.encoding.as_deref()
            } else if file.used_fallback {
                request.fallback_encoding.as_deref()
            } else {
                None
            },
            max_file_size_mib,
        ) {
            Ok(document) => document,
            Err(error) => {
                failures.push(Issue {
                    path: file.path.clone(),
                    message: error,
                });
                continue;
            }
        };
        let current_identity = match PathIdentity::for_existing(document.target_path()) {
            Ok(identity) => identity,
            Err(error) => {
                failures.push(Issue {
                    path: file.path.clone(),
                    message: error,
                });
                continue;
            }
        };
        if current_identity != file.identity {
            failures.push(Issue {
                path: file.path.clone(),
                message: format!(
                    "{} changed on disk during the edit; nothing was written. Re-read it and retry.",
                    file.path
                ),
            });
            continue;
        }
        if document.revision() != file.revision {
            failures.push(Issue {
                path: file.path.clone(),
                message: format!(
                    "{} changed on disk during the edit; nothing was written. Re-read it and retry.",
                    file.path
                ),
            });
            continue;
        }
        let built =
            match build_replacement(&document, &regex, &request.replacement, max_file_size_mib) {
                Ok(built) => built,
                Err(error) => {
                    failures.push(Issue {
                        path: file.path.clone(),
                        message: error,
                    });
                    continue;
                }
            };
        if built.matches != file.matches {
            failures.push(Issue {
                path: file.path.clone(),
                message: format!(
                    "{} changed on disk during the edit; nothing was written. Re-read it and retry.",
                    file.path
                ),
            });
            continue;
        }
        if built.bytes == document.original_bytes() {
            successes.push((original_index, file.path.clone(), built.matches));
            written_replacements = written_replacements.saturating_add(built.matches);
            continue;
        }
        match document.commit(&built.bytes) {
            Ok(()) => {
                successes.push((original_index, file.path.clone(), built.matches));
                written_replacements = written_replacements.saturating_add(built.matches);
            }
            Err(error) => failures.push(Issue {
                path: file.path.clone(),
                message: error,
            }),
        }
    }

    successes.sort_by_key(|(index, _, _)| *index);
    let successes = successes
        .into_iter()
        .map(|(_, path, matches)| (path, matches))
        .collect::<Vec<_>>();
    failures.sort_by(|left, right| {
        left.path
            .as_bytes()
            .cmp(right.path.as_bytes())
            .then_with(|| left.message.as_bytes().cmp(right.message.as_bytes()))
    });

    format_apply(
        &successes,
        &skipped,
        &failures,
        written_replacements,
        budget,
        &fallback_note(&analyzed, fallback_label),
    )
}

fn preview_slot_limit(dry_run: bool, budget: usize) -> usize {
    if dry_run {
        budget.min(MAX_STORED_PREVIEWS)
    } else {
        0
    }
}

struct FileAnalysis {
    matches: usize,
    previews: Vec<String>,
    #[cfg(test)]
    preview_scan_bytes: usize,
}

fn analyze_file(
    document: &TextDocument,
    regex: &Regex,
    replacement: &str,
    preview_limit: usize,
) -> FileAnalysis {
    let text = document.logical_text();
    let mut matches = 0_usize;
    let mut previews = Vec::new();
    let mut tracker = PreviewTracker::new();

    if is_fixed_replacement(replacement) {
        for matched in regex.find_iter(text) {
            record_analysis_match(
                text,
                matched,
                replacement,
                preview_limit,
                &mut matches,
                &mut previews,
                &mut tracker,
            );
        }
    } else {
        let mut expanded = String::new();
        for captures in regex.captures_iter(text) {
            let matched = captures.get(0).expect("every capture set has group zero");
            if matched.start() != matched.end() && previews.len() >= preview_limit {
                matches = matches.saturating_add(1);
                continue;
            }
            expanded.clear();
            captures.expand(replacement, &mut expanded);
            record_analysis_match(
                text,
                matched,
                &expanded,
                preview_limit,
                &mut matches,
                &mut previews,
                &mut tracker,
            );
        }
    }

    FileAnalysis {
        matches,
        previews,
        #[cfg(test)]
        preview_scan_bytes: tracker.scan_bytes,
    }
}

struct PreviewTracker {
    line: usize,
    cursor: usize,
    #[cfg(test)]
    scan_bytes: usize,
}

impl PreviewTracker {
    fn new() -> Self {
        Self {
            line: 1,
            cursor: 0,
            #[cfg(test)]
            scan_bytes: 0,
        }
    }
}

fn record_analysis_match(
    text: &str,
    matched: regex::Match<'_>,
    expanded: &str,
    preview_limit: usize,
    matches: &mut usize,
    previews: &mut Vec<String>,
    tracker: &mut PreviewTracker,
) {
    if matched.start() == matched.end() && expanded.is_empty() {
        return;
    }
    *matches = matches.saturating_add(1);
    if previews.len() >= preview_limit {
        return;
    }

    let preview_region = &text[tracker.cursor..matched.start()];
    tracker.line = tracker
        .line
        .saturating_add(preview_region.bytes().filter(|byte| *byte == b'\n').count());
    tracker.cursor = matched.start();
    #[cfg(test)]
    {
        tracker.scan_bytes = tracker.scan_bytes.saturating_add(preview_region.len());
    }
    previews.push(format!(
        "{}: {} -> {}",
        tracker.line,
        preview_text(matched.as_str()),
        preview_text(expanded)
    ));
}

struct BuiltReplacement {
    bytes: Vec<u8>,
    matches: usize,
}

struct ReplacementOutput {
    bytes: Option<Vec<u8>>,
    len: usize,
}

impl ReplacementOutput {
    fn new(capacity: usize, materialize: bool) -> Self {
        Self {
            bytes: materialize.then(|| Vec::with_capacity(capacity)),
            len: 0,
        }
    }

    fn extend(&mut self, bytes: &[u8], path: &str, max_result_size_mib: u64) -> Result<(), String> {
        self.len = checked_result_size(self.len, bytes.len(), path, max_result_size_mib)?;
        if let Some(output) = &mut self.bytes {
            output.extend_from_slice(bytes);
        }
        Ok(())
    }

    fn remove_suffix(&mut self, suffix: &[u8]) {
        let suffix_is_present = self
            .bytes
            .as_ref()
            .is_none_or(|output| output.ends_with(suffix));
        if suffix_is_present && self.len >= suffix.len() {
            self.len -= suffix.len();
            if let Some(output) = &mut self.bytes {
                output.truncate(self.len);
            }
        }
    }
}

fn validate_replacement(
    document: &TextDocument,
    regex: &Regex,
    replacement: &str,
    max_result_size_mib: u64,
) -> Result<(), String> {
    process_replacement(document, regex, replacement, max_result_size_mib, false).map(drop)
}

fn build_replacement(
    document: &TextDocument,
    regex: &Regex,
    replacement: &str,
    max_result_size_mib: u64,
) -> Result<BuiltReplacement, String> {
    let (output, matches) =
        process_replacement(document, regex, replacement, max_result_size_mib, true)?;
    Ok(BuiltReplacement {
        bytes: output
            .bytes
            .expect("materialized replacement always has an output buffer"),
        matches,
    })
}

fn process_replacement(
    document: &TextDocument,
    regex: &Regex,
    replacement: &str,
    max_result_size_mib: u64,
    materialize: bool,
) -> Result<(ReplacementOutput, usize), String> {
    let mut pass = ReplacementPass::new(document, max_result_size_mib, materialize)?;

    if is_fixed_replacement(replacement) {
        let mut encoded = None;
        for matched in regex.find_iter(document.logical_text()) {
            if !is_effective_match(&matched, replacement) {
                continue;
            }
            if encoded.is_none() {
                encoded = Some(document.encode_for_target(replacement)?);
            }
            pass.push(matched, replacement, encoded.as_deref().unwrap())?;
        }
    } else {
        let mut expanded = String::new();
        for captures in regex.captures_iter(document.logical_text()) {
            expanded.clear();
            captures.expand(replacement, &mut expanded);
            let matched = captures.get(0).expect("every capture set has group zero");
            if !is_effective_match(&matched, &expanded) {
                continue;
            }
            let encoded = document.encode_for_target(&expanded)?;
            pass.push(matched, &expanded, &encoded)?;
        }
    }

    pass.finish()
}

struct ReplacementPass<'a> {
    document: &'a TextDocument,
    output: ReplacementOutput,
    raw_cursor: super::document::RawOffsetCursor<'a>,
    previous_raw: usize,
    previous_logical: usize,
    matches: usize,
    result_ends_newline: bool,
    path: String,
    max_result_size_mib: u64,
}

impl<'a> ReplacementPass<'a> {
    fn new(
        document: &'a TextDocument,
        max_result_size_mib: u64,
        materialize: bool,
    ) -> Result<Self, String> {
        Ok(Self {
            document,
            output: ReplacementOutput::new(document.original_bytes().len(), materialize),
            raw_cursor: document.raw_offset_cursor()?,
            previous_raw: 0,
            previous_logical: 0,
            matches: 0,
            result_ends_newline: false,
            path: document.display_path(),
            max_result_size_mib,
        })
    }

    fn push(
        &mut self,
        matched: regex::Match<'_>,
        expanded: &str,
        encoded: &[u8],
    ) -> Result<(), String> {
        debug_assert!(is_effective_match(&matched, expanded));
        let raw_start = self.raw_cursor.advance_to(matched.start())?;
        let raw_end = self.raw_cursor.advance_to(matched.end())?;
        self.output.extend(
            &self.document.original_bytes()[self.previous_raw..raw_start],
            &self.path,
            self.max_result_size_mib,
        )?;
        observe_tail(
            &self.document.logical_text()[self.previous_logical..matched.start()],
            &mut self.result_ends_newline,
        );
        self.output
            .extend(encoded, &self.path, self.max_result_size_mib)?;
        observe_tail(expanded, &mut self.result_ends_newline);
        self.previous_raw = raw_end;
        self.previous_logical = matched.end();
        self.matches = self.matches.saturating_add(1);
        Ok(())
    }

    fn finish(mut self) -> Result<(ReplacementOutput, usize), String> {
        self.output.extend(
            &self.document.original_bytes()[self.previous_raw..],
            &self.path,
            self.max_result_size_mib,
        )?;
        observe_tail(
            &self.document.logical_text()[self.previous_logical..],
            &mut self.result_ends_newline,
        );

        let newline = self.document.encode_for_target("\n")?;
        if self.document.trailing_newline() && !self.result_ends_newline {
            self.output
                .extend(&newline, &self.path, self.max_result_size_mib)?;
        } else if !self.document.trailing_newline() && self.result_ends_newline {
            self.output.remove_suffix(&newline);
        }
        Ok((self.output, self.matches))
    }
}

fn is_fixed_replacement(replacement: &str) -> bool {
    !replacement.as_bytes().contains(&b'$')
}

fn is_effective_match(matched: &regex::Match<'_>, expanded: &str) -> bool {
    matched.start() != matched.end() || !expanded.is_empty()
}

fn checked_result_size(
    current: usize,
    additional: usize,
    path: &str,
    max_result_size_mib: u64,
) -> Result<usize, String> {
    let projected = current.saturating_add(additional);
    let maximum_bytes = max_result_size_mib.saturating_mul(1024 * 1024);
    if u64::try_from(projected).unwrap_or(u64::MAX) > maximum_bytes {
        return Err(format!(
            "Refusing to write {path}: the result would be {:.1} MiB, over the {max_result_size_mib} MiB safety limit. Narrow the pattern.",
            projected as f64 / 1_048_576.0
        ));
    }
    Ok(projected)
}

fn observe_tail(text: &str, ends_newline: &mut bool) {
    if !text.is_empty() {
        *ends_newline = text.ends_with('\n');
    }
}

fn open_candidate(
    path: &str,
    explicit: Option<&str>,
    fallback: Option<&str>,
    max_file_size_mib: u64,
) -> Result<(TextDocument, bool), String> {
    match TextDocument::open(path, explicit, max_file_size_mib) {
        Ok(document) => Ok((document, false)),
        Err(error)
            if explicit.is_none()
                && fallback.is_some()
                && is_encoding_error(&error)
                && !error.contains("byte order mark") =>
        {
            TextDocument::open(path, fallback, max_file_size_mib).map(|document| (document, true))
        }
        Err(error) => Err(error),
    }
}

#[derive(Debug)]
struct CompiledRegex {
    regex: Regex,
    can_match_empty: bool,
}

fn build_regex(request: &ReplaceRequest) -> Result<CompiledRegex, String> {
    if request.pattern.is_empty() {
        return Err(
            "An empty pattern matches at every position and is almost always a mistake. Give a non-empty pattern."
                .to_string(),
        );
    }
    let pattern = if request.literal.unwrap_or(false) {
        regex::escape(&request.pattern)
    } else {
        request.pattern.clone()
    };
    let regex = RegexBuilder::new(&pattern)
        .case_insensitive(request.case_insensitive.unwrap_or(false))
        .dot_matches_new_line(request.dot_all.unwrap_or(false))
        .build()
        .map_err(|error| {
            format!(
                "Invalid regex pattern: {error}\nNote: Rust regex syntax — no lookaround or backreferences; escape literal braces."
            )
        })?;
    let hir = regex_syntax::Parser::new().parse(&pattern).map_err(|error| {
        format!(
            "Invalid regex pattern: {error}\nNote: Rust regex syntax — no lookaround or backreferences; escape literal braces."
        )
    })?;
    Ok(CompiledRegex {
        regex,
        can_match_empty: hir.properties().minimum_len() == Some(0),
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReplacementReference<'a> {
    Number(usize),
    Named(&'a str),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ReplacementToken<'a> {
    token: &'a str,
    reference: ReplacementReference<'a>,
}

fn validate_replacement_references(regex: &Regex, replacement: &str) -> Result<(), String> {
    let names = regex.capture_names().flatten().collect::<Vec<_>>();
    for token in replacement_tokens(replacement) {
        let defined = match token.reference {
            ReplacementReference::Number(index) => index < regex.captures_len(),
            ReplacementReference::Named(name) => names.contains(&name),
        };
        if !defined {
            return Err(format!(
                "Replacement references an undefined capture group: {}. The pattern defines {}. Fix the replacement; nothing was written.",
                token.token,
                available_groups(regex, &names)
            ));
        }
    }
    Ok(())
}

fn available_groups(regex: &Regex, names: &[&str]) -> String {
    let numbered = regex.captures_len().saturating_sub(1);
    match (numbered, names) {
        (0, []) => "no capture groups".to_string(),
        (1, []) => "group 1".to_string(),
        (count, []) => format!("groups 1-{count}"),
        (0, [name]) => format!("named group: {name}"),
        (0, names) => format!("named groups: {}", names.join(", ")),
        (1, [name]) => format!("group 1; named group: {name}"),
        (count, [name]) => format!("groups 1-{count}; named group: {name}"),
        (1, names) => format!("group 1; named groups: {}", names.join(", ")),
        (count, names) => format!("groups 1-{count}; named groups: {}", names.join(", ")),
    }
}

fn replacement_tokens(replacement: &str) -> Vec<ReplacementToken<'_>> {
    let bytes = replacement.as_bytes();
    let mut tokens = Vec::new();
    let mut cursor = 0_usize;
    while cursor < bytes.len() {
        let Some(relative) = bytes[cursor..].iter().position(|byte| *byte == b'$') else {
            break;
        };
        let start = cursor + relative;
        if bytes.get(start + 1) == Some(&b'$') {
            cursor = start + 2;
            continue;
        }
        let Some(next) = bytes.get(start + 1).copied() else {
            break;
        };
        let (reference_text, end) = if next == b'{' {
            let content_start = start + 2;
            let Some(relative_end) = bytes[content_start..].iter().position(|byte| *byte == b'}')
            else {
                cursor = start + 1;
                continue;
            };
            let content_end = content_start + relative_end;
            (&replacement[content_start..content_end], content_end + 1)
        } else {
            let content_start = start + 1;
            let mut content_end = content_start;
            while bytes
                .get(content_end)
                .is_some_and(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'z' | b'A'..=b'Z' | b'_'))
            {
                content_end += 1;
            }
            if content_end == content_start {
                cursor = start + 1;
                continue;
            }
            (&replacement[content_start..content_end], content_end)
        };
        let reference = reference_text
            .parse::<usize>()
            .map(ReplacementReference::Number)
            .unwrap_or(ReplacementReference::Named(reference_text));
        tokens.push(ReplacementToken {
            token: &replacement[start..end],
            reference,
        });
        cursor = end;
    }
    tokens
}

fn build_glob(pattern: Option<&str>) -> Result<Option<GlobSet>, String> {
    let Some(pattern) = pattern else {
        return Ok(None);
    };
    let glob = Glob::new(pattern).map_err(|error| {
        format!("Invalid glob pattern: {error}. Use forms like \"*.rs\" or \"**/*.{{ts,tsx}}\".")
    })?;
    let mut builder = GlobSetBuilder::new();
    builder.add(glob);
    builder.build().map(Some).map_err(|error| {
        format!("Invalid glob pattern: {error}. Use forms like \"*.rs\" or \"**/*.{{ts,tsx}}\".")
    })
}

fn resolve_root(input: &str) -> Result<PathBuf, String> {
    let parsed = crate::paths::parse_input_path(input);
    if !parsed.is_absolute() || !parsed.exists() {
        return Err(crate::paths::missing_search_path_message(input));
    }
    fs::metadata(&parsed).map_err(|error| crate::paths::io_error_message(&parsed, &error))?;
    Ok(crate::paths::canonical_existing(&parsed).unwrap_or(parsed))
}

fn format_dry_run(
    analyzed: &[AnalyzedFile],
    skipped: &[Issue],
    failures: &[Issue],
    total_matches: usize,
    budget: usize,
    fallback_label: Option<&str>,
) -> ToolResponse {
    let mut groups = analyzed
        .iter()
        .map(|file| {
            let mut lines = vec![file.path.clone()];
            lines.extend(file.previews.iter().cloned());
            ReportGroup { lines }
        })
        .collect::<Vec<_>>();
    groups.extend(issue_groups(skipped, "skipped"));
    groups.extend(issue_groups(failures, "failed"));
    let matched_files = analyzed.len();
    let mut terminal = if total_matches == 0 {
        "(Complete: dry run — no matches found.)".to_string()
    } else {
        format!(
            "(Complete: dry run — {total_matches} {} in {matched_files} {}; nothing written.)",
            plural(total_matches, "match", "matches"),
            plural(matched_files, "file", "files")
        )
    };
    if !skipped.is_empty() || !failures.is_empty() {
        terminal = append_terminal_clause(
            &terminal,
            &format!(
                "{} {} skipped",
                skipped.len() + failures.len(),
                plural(skipped.len() + failures.len(), "file", "files")
            ),
        );
    }
    render_report(
        &groups,
        &terminal,
        &fallback_note(analyzed, fallback_label),
        budget,
        analyzed.iter().any(|file| file.previews_truncated),
    )
}

fn format_apply(
    successes: &[(String, usize)],
    skipped: &[Issue],
    failures: &[Issue],
    replacements: usize,
    budget: usize,
    extra_notes: &[String],
) -> ToolResponse {
    let mut groups = successes
        .iter()
        .map(|(path, count)| ReportGroup {
            lines: vec![format!(
                "{path}: {count} {}",
                plural(*count, "replacement", "replacements")
            )],
        })
        .collect::<Vec<_>>();
    groups.extend(issue_groups(skipped, "skipped"));
    groups.extend(issue_groups(failures, "failed"));
    let mut terminal = if replacements == 0 && failures.is_empty() {
        "(Complete: no matches found; nothing written.)".to_string()
    } else if failures.is_empty() {
        format!(
            "(Complete: {replacements} {} in {} {}.)",
            plural(replacements, "replacement", "replacements"),
            successes.len(),
            plural(successes.len(), "file", "files")
        )
    } else {
        format!(
            "(Partial: {replacements} {} written in {} {}; {} {} failed — see the report above.)",
            plural(replacements, "replacement", "replacements"),
            successes.len(),
            plural(successes.len(), "file", "files"),
            failures.len(),
            plural(failures.len(), "file", "files")
        )
    };
    if !skipped.is_empty() {
        terminal = append_terminal_clause(
            &terminal,
            &format!(
                "{} {} skipped",
                skipped.len(),
                plural(skipped.len(), "file", "files")
            ),
        );
    }
    render_report(&groups, &terminal, extra_notes, budget, false)
}

fn render_report(
    groups: &[ReportGroup],
    terminal: &str,
    extra_notes: &[String],
    budget: usize,
    force_truncated: bool,
) -> ToolResponse {
    let all_lines = groups
        .iter()
        .flat_map(|group| group.lines.iter().cloned())
        .collect::<Vec<_>>();
    let mut notes = extra_notes.to_vec();
    notes.push(terminal.to_string());
    let full = assemble_text(&all_lines, &notes);
    if !force_truncated && estimate_tokens(&full) <= budget {
        return ToolResponse::text(full);
    }
    let truncated_terminal = append_terminal_clause(terminal, "list truncated, see the note above");
    let mut shown_lines = Vec::new();
    let mut shown_files = 0_usize;
    let mut counter = ExactPrefixCounter::default();
    for group in groups {
        let start_len = shown_lines.len();
        for line in &group.lines {
            let checkpoint = counter.checkpoint();
            if !shown_lines.is_empty()
                && let Err(error) = counter.append("\n", None)
            {
                return report_render_error(error);
            }
            if let Err(error) = counter.append(line, None) {
                return report_render_error(error);
            }
            shown_lines.push(line.clone());
            let mut trial_notes = vec![format!(
                "(Note: showing {} of {} files; totals below cover all files.)",
                shown_files + 1,
                groups.len()
            )];
            trial_notes.extend(extra_notes.iter().cloned());
            trial_notes.push(truncated_terminal.clone());
            let tokens = match count_report_with_notes(&mut counter, true, &trial_notes) {
                Ok(tokens) => tokens,
                Err(error) => return report_render_error(error),
            };
            if tokens > budget {
                shown_lines.pop();
                counter = ExactPrefixCounter::from_checkpoint(&checkpoint);
                break;
            }
        }
        if shown_lines.len() > start_len {
            shown_files += 1;
        }
        let mut trial_notes = vec![format!(
            "(Note: showing {shown_files} of {} files; totals below cover all files.)",
            groups.len()
        )];
        trial_notes.extend(extra_notes.iter().cloned());
        trial_notes.push(truncated_terminal.clone());
        let tokens =
            match count_report_with_notes(&mut counter, !shown_lines.is_empty(), &trial_notes) {
                Ok(tokens) => tokens,
                Err(error) => return report_render_error(error),
            };
        if tokens >= budget {
            break;
        }
    }
    let mut truncated_notes = vec![format!(
        "(Note: showing {shown_files} of {} files; totals below cover all files.)",
        groups.len()
    )];
    truncated_notes.extend(extra_notes.iter().cloned());
    truncated_notes.push(truncated_terminal);
    let incremental =
        match count_report_with_notes(&mut counter, !shown_lines.is_empty(), &truncated_notes) {
            Ok(tokens) => tokens,
            Err(error) => return report_render_error(error),
        };
    let output = assemble_text(&shown_lines, &truncated_notes);
    let required = estimate_tokens(&output);
    if required != incremental {
        return ToolResponse::error(format!(
            "Internal replacement report token count mismatch: incremental={incremental}, full={required}."
        ));
    }
    if required <= budget {
        ToolResponse::text(output)
    } else {
        if let Ok(expanded) = tool_token_budget_for_required(GLOBAL_TOKEN_BUDGET_ENV, required)
            && expanded.value > budget
        {
            return render_report(
                groups,
                terminal,
                extra_notes,
                expanded.value,
                force_truncated,
            );
        }
        ToolResponse::error(format!(
            "FASTCTX_TOKEN_BUDGET={budget} is too small to return the required status note. Increase it and retry."
        ))
    }
}

fn count_report_with_notes(
    counter: &mut ExactPrefixCounter,
    has_body: bool,
    notes: &[String],
) -> Result<usize, crate::budget::TokenCountError> {
    let checkpoint = counter.checkpoint();
    let mut suffix = String::new();
    if !notes.is_empty() {
        if has_body {
            suffix.push_str("\n\n");
        }
        suffix.push_str(&notes.join("\n"));
    }
    counter.count_with_suffix(&checkpoint, &suffix, None)
}

fn report_render_error(error: crate::budget::TokenCountError) -> ToolResponse {
    ToolResponse::error(format!(
        "Internal replacement report rendering failed: {error}"
    ))
}

fn issue_groups(issues: &[Issue], label: &str) -> Vec<ReportGroup> {
    issues
        .iter()
        .map(|issue| ReportGroup {
            lines: vec![format!("{} — {label}: {}", issue.path, issue.message)],
        })
        .collect()
}

fn fallback_note(analyzed: &[AnalyzedFile], encoding: Option<&str>) -> Vec<String> {
    let count = analyzed.iter().filter(|file| file.used_fallback).count();
    if count == 0 {
        Vec::new()
    } else {
        let encoding = encoding.unwrap_or("the requested fallback");
        vec![format!(
            "(Note: {count} {} decoded using fallback encoding {encoding}.)",
            plural(count, "file", "files"),
        )]
    }
}

fn append_terminal_clause(terminal: &str, clause: &str) -> String {
    let stem = terminal
        .strip_suffix(".)")
        .expect("replace terminal notes always end with .)");
    format!("{stem}; {clause}.)")
}

fn preview_text(text: &str) -> String {
    let escaped = text
        .replace("\r\n", "\\n")
        .replace('\n', "\\n")
        .replace('\r', "\\r");
    let total = escaped.chars().count();
    let shown = escaped.chars().take(160).collect::<String>();
    if total > 160 {
        format!("{shown}…")
    } else {
        shown
    }
}

fn is_binary_error(error: &str) -> bool {
    error.starts_with("Cannot read binary file as text:")
}

fn is_encoding_error(error: &str) -> bool {
    error.starts_with("Cannot determine the text encoding") || error.starts_with("Cannot decode ")
}

fn is_skippable_error(error: &str) -> bool {
    is_encoding_error(error) || error.starts_with("File too large for line edits:")
}

fn short_issue(error: &str) -> String {
    if error.contains("mixed or inconsistent encodings") {
        "mixed or inconsistent encodings".to_string()
    } else if error.starts_with("Cannot determine the text encoding") {
        "ambiguous encoding".to_string()
    } else if error.starts_with("Cannot decode ") {
        "undecodable".to_string()
    } else {
        error.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ReportGroup, analyze_file, build_regex, build_replacement, is_fixed_replacement,
        preview_slot_limit, preview_text, render_report, validate_replacement_references,
    };
    use crate::edit::{ReplaceRequest, document::TextDocument};
    use crate::{ToolContent, budget::estimate_tokens};

    fn request(pattern: &str, replacement: &str) -> ReplaceRequest {
        ReplaceRequest {
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            path: "/tmp".to_string(),
            glob: None,
            literal: None,
            case_insensitive: None,
            dot_all: None,
            max_replacements: None,
            dry_run: None,
            encoding: None,
            fallback_encoding: None,
        }
    }

    #[test]
    fn captures_dollars_and_pattern_width_guards_follow_regex_semantics() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("replace.txt");
        std::fs::write(&path, b"ab ab").unwrap();
        let document = TextDocument::open(path.to_str().unwrap(), None, 256).unwrap();
        let compiled = build_regex(&request("(a)(b)", "$2$1$$")).unwrap();
        let analysis = analyze_file(&document, &compiled.regex, "$2$1$$", usize::MAX);
        assert_eq!(analysis.matches, 2);
        assert!(!compiled.can_match_empty);

        assert_eq!(
            build_regex(&request("", "")).unwrap_err(),
            "An empty pattern matches at every position and is almost always a mistake. Give a non-empty pattern."
        );
        assert!(build_regex(&request("x*", "y")).unwrap().can_match_empty);
        assert!(build_regex(&request(r"\b", "y")).unwrap().can_match_empty);
    }

    #[test]
    fn replacement_references_are_validated_with_the_engine_token_grammar() {
        let compiled = build_regex(&request("(?P<name>a)(b)?", "")).unwrap();
        for replacement in ["$0", "$1", "${1}", "$2", "$name", "${name}", "$$", "$"] {
            validate_replacement_references(&compiled.regex, replacement).unwrap();
        }
        for (replacement, token) in [
            ("$3", "$3"),
            ("${missing}", "${missing}"),
            ("$1a", "$1a"),
            ("$nameX", "$nameX"),
        ] {
            assert_eq!(
                validate_replacement_references(&compiled.regex, replacement).unwrap_err(),
                format!(
                    "Replacement references an undefined capture group: {token}. The pattern defines groups 1-2; named group: name. Fix the replacement; nothing was written."
                )
            );
        }
        validate_replacement_references(&compiled.regex, "${1}a ${name}X").unwrap();
    }

    #[test]
    fn preview_slots_are_disabled_for_apply_and_bounded_by_dry_run_budget() {
        assert_eq!(preview_slot_limit(false, usize::MAX), 0);
        assert_eq!(preview_slot_limit(true, 1), 1);
        assert_eq!(preview_slot_limit(true, 8_500), 8_500);
        assert_eq!(preview_slot_limit(true, usize::MAX), 100_000);
    }

    #[test]
    fn fixed_replacement_classification_matches_the_regex_engine_fast_path() {
        for replacement in ["", "plain", "line\nbreak", "界"] {
            assert!(is_fixed_replacement(replacement), "{replacement:?}");
        }
        for replacement in ["$", "$$", "$0", "${name}", "plain$value"] {
            assert!(!is_fixed_replacement(replacement), "{replacement:?}");
        }
    }

    #[test]
    fn fixed_and_capture_paths_produce_identical_raw_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let cases = vec![
            ("mixed.txt", b"prefix\r\nold\nsuffix\r\n".to_vec(), None),
            ("no-trailing.txt", b"old".to_vec(), None),
            ("trailing.txt", b"old\r\n".to_vec(), None),
            (
                "utf16.txt",
                utf16le_with_bom("prefix\r\nold\r\nsuffix"),
                None,
            ),
            (
                "gbk.txt",
                encode_legacy(encoding_rs::GBK, "中文前缀\r\nold\r\n中文后缀"),
                Some("gbk"),
            ),
        ];
        let regex = regex::Regex::new("(old)()").unwrap();

        for (name, bytes, encoding) in cases {
            let path = temp.path().join(name);
            std::fs::write(&path, bytes).unwrap();
            let document = TextDocument::open(path.to_str().unwrap(), encoding, 256).unwrap();
            for (fixed, dynamic) in [("NEW", "NEW$2"), ("", "$2"), ("NEW\n", "NEW\n$2")] {
                let fixed = build_replacement(&document, &regex, fixed, 256).unwrap();
                let dynamic = build_replacement(&document, &regex, dynamic, 256).unwrap();
                assert_eq!(fixed.bytes, dynamic.bytes, "{name}");
                assert_eq!(fixed.matches, dynamic.matches, "{name}");
            }
        }
    }

    #[test]
    fn fixed_and_capture_paths_agree_for_zero_width_matches() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("zero-width.txt");
        std::fs::write(&path, b"ab").unwrap();
        let document = TextDocument::open(path.to_str().unwrap(), None, 256).unwrap();
        let regex = regex::Regex::new("(x*)()").unwrap();

        for (fixed, dynamic) in [("X", "X$2"), ("", "$2")] {
            let fixed = build_replacement(&document, &regex, fixed, 256).unwrap();
            let dynamic = build_replacement(&document, &regex, dynamic, 256).unwrap();
            assert_eq!(fixed.bytes, dynamic.bytes);
            assert_eq!(fixed.matches, dynamic.matches);
        }
    }

    #[test]
    fn dense_fixed_replacement_build_materializes_every_match_without_preview_work() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("dense-build.txt");
        let source = (0..20_000)
            .map(|index| format!("{index:05}: OLD_TOKEN tail\n"))
            .collect::<String>();
        std::fs::write(&path, &source).unwrap();
        let document = TextDocument::open(path.to_str().unwrap(), None, 256).unwrap();
        let regex = regex::Regex::new("OLD_TOKEN").unwrap();
        let built = build_replacement(&document, &regex, "NEW_TOKEN", 256).unwrap();

        assert_eq!(built.matches, 20_000);
        assert_eq!(
            built
                .bytes
                .windows(b"NEW_TOKEN".len())
                .filter(|window| *window == b"NEW_TOKEN")
                .count(),
            20_000
        );
        assert!(
            !built
                .bytes
                .windows(b"OLD_TOKEN".len())
                .any(|window| window == b"OLD_TOKEN")
        );
    }

    #[test]
    fn truncated_reports_skip_oversized_groups_and_continue_with_later_files() {
        let groups = vec![
            ReportGroup {
                lines: vec!["first".to_string(), "x".repeat(1_000)],
            },
            ReportGroup {
                lines: vec!["second".to_string()],
            },
        ];
        let terminal = "(Complete: dry run — 2 matches in 2 files; nothing written.)";
        let response = render_report(&groups, terminal, &[], 70, true);
        assert!(!response.is_error);
        let [ToolContent::Text(text)] = response.content.as_slice() else {
            panic!("expected text report")
        };
        assert!(text.contains("first"), "{text}");
        assert!(!text.contains(&"x".repeat(1_000)), "{text}");
        assert!(text.contains("second"), "{text}");
        assert!(estimate_tokens(text) <= 70, "{text}");
    }

    #[test]
    fn dense_preview_line_tracking_is_linear_and_preview_free_analysis_scans_no_lines() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("dense.txt");
        let text = (0..10_000)
            .map(|index| format!("line-{index:05} hit\n"))
            .collect::<String>();
        std::fs::write(&path, &text).unwrap();
        let document = TextDocument::open(path.to_str().unwrap(), None, 256).unwrap();
        let compiled = build_regex(&request("hit", "MISS")).unwrap();

        let with_previews = analyze_file(&document, &compiled.regex, "MISS", usize::MAX);
        assert_eq!(with_previews.matches, 10_000);
        assert_eq!(with_previews.previews.len(), 10_000);
        assert_eq!(with_previews.previews[0], "1: hit -> MISS");
        assert_eq!(with_previews.previews[9_999], "10000: hit -> MISS");
        assert!(with_previews.preview_scan_bytes <= text.len());

        let without_previews = analyze_file(&document, &compiled.regex, "MISS", 0);
        assert_eq!(without_previews.matches, 10_000);
        assert!(without_previews.previews.is_empty());
        assert_eq!(without_previews.preview_scan_bytes, 0);
    }

    #[test]
    fn preview_windows_are_single_line_and_character_bounded() {
        assert_eq!(preview_text("a\r\nb"), "a\\nb");
        assert_eq!(preview_text(&"界".repeat(161)).chars().count(), 161);
    }

    #[test]
    fn replacement_size_guard_accepts_the_exact_limit_and_rejects_one_byte_more() {
        assert_eq!(
            super::checked_result_size(256 * 1024 * 1024 - 1, 1, "target", 256),
            Ok(256 * 1024 * 1024)
        );
        assert_eq!(
            super::checked_result_size(256 * 1024 * 1024, 1, "target", 256).unwrap_err(),
            "Refusing to write target: the result would be 256.0 MiB, over the 256 MiB safety limit. Narrow the pattern."
        );
    }

    fn utf16le_with_bom(text: &str) -> Vec<u8> {
        let mut bytes = vec![0xff, 0xfe];
        for unit in text.encode_utf16() {
            bytes.extend(unit.to_le_bytes());
        }
        bytes
    }

    fn encode_legacy(encoding: &'static encoding_rs::Encoding, text: &str) -> Vec<u8> {
        let (bytes, _, had_errors) = encoding.encode(text);
        assert!(!had_errors);
        bytes.into_owned()
    }
}
