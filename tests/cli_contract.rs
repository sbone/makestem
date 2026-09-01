#![cfg(unix)]

use serde_json::Value;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Output},
    time::{SystemTime, UNIX_EPOCH},
};

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new(label: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "makestem-test-{label}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn executable() -> &'static str {
    env!("CARGO_BIN_EXE_makestem")
}

fn write_executable(path: &Path, contents: &str) {
    fs::write(path, contents).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn json_lines(output: &Output) -> Vec<Value> {
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|line| serde_json::from_str(line).expect("each protocol line must be valid JSON"))
        .collect()
}

#[test]
fn inspect_json_preserves_unicode_paths_and_reports_compressed_audio() {
    let temporary = TestDirectory::new("inspect");
    let tools = temporary.path().join("tools");
    fs::create_dir(&tools).unwrap();
    write_executable(
        &tools.join("ffprobe"),
        r#"#!/bin/sh
printf '%s\n' '{"streams":[{"codec_name":"mp3","codec_type":"audio","sample_rate":"44100","channels":2}],"format":{"format_name":"mp3","duration":"245.5","tags":{"TITLE":"A Test Blend"}}}'
"#,
    );
    let track = temporary.path().join("Beyoncé – test 🎧.mp3");
    fs::write(&track, b"fixture").unwrap();

    let output = Command::new(executable())
        .args(["--inspect-json", track.to_str().unwrap()])
        .env("PATH", &tools)
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let inspection: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(inspection["path"], track.to_string_lossy().as_ref());
    assert_eq!(inspection["title"], "A Test Blend");
    assert_eq!(inspection["format"], "MP3");
    assert_eq!(inspection["readiness"], "warning");
    assert_eq!(inspection["lossless"], false);
    assert_eq!(inspection["sample_rate"], 44_100);
}

#[test]
fn events_json_returns_a_machine_readable_missing_tool_error() {
    let temporary = TestDirectory::new("missing-tool");
    let track = temporary.path().join("track.wav");
    fs::write(&track, b"fixture").unwrap();

    let output = Command::new(executable())
        .args(["--events-json", track.to_str().unwrap()])
        .env("PATH", temporary.path())
        .output()
        .unwrap();

    assert!(!output.status.success());
    let events = json_lines(&output);
    assert_eq!(events[0]["type"], "stage_started");
    assert_eq!(events[0]["label"], "Checking required tools");
    assert_eq!(events.last().unwrap()["type"], "error");
    assert!(
        events.last().unwrap()["message"]
            .as_str()
            .unwrap()
            .contains("demucs")
    );
    assert!(events.last().unwrap()["guidance"].is_string());
}

#[test]
fn missing_track_is_a_usage_error() {
    let output = Command::new(executable()).output().unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("source track is required"));
}

#[test]
fn existing_output_is_refused_before_separation_without_replace() {
    let temporary = TestDirectory::new("existing-output");
    let tools = temporary.path().join("tools");
    fs::create_dir(&tools).unwrap();
    write_executable(
        &tools.join("ffprobe"),
        r#"#!/bin/sh
case "$*" in
  *stream=codec_name*) printf 'flac\n' ;;
  *format_tags=title*) printf 'Existing Test\n' ;;
esac
"#,
    );
    write_executable(&tools.join("ffmpeg"), "#!/bin/sh\nexit 0\n");
    write_executable(&tools.join("demucs"), "#!/bin/sh\nexit 0\n");
    let track = temporary.path().join("track.flac");
    fs::write(&track, b"fixture").unwrap();
    let output_directory = temporary.path().join("output");
    fs::create_dir(&output_directory).unwrap();
    let existing = output_directory.join("track (Acapella).mp3");
    fs::write(&existing, b"original stem").unwrap();

    let output = Command::new(executable())
        .args(["--events-json", "--acapella", track.to_str().unwrap()])
        .env("PATH", &tools)
        .output()
        .unwrap();

    assert!(!output.status.success());
    let events = json_lines(&output);
    assert!(
        events.last().unwrap()["message"]
            .as_str()
            .unwrap()
            .contains("Output already exists")
    );
    assert!(
        events.last().unwrap()["guidance"]
            .as_str()
            .unwrap()
            .contains("--replace")
    );
    assert_eq!(fs::read(existing).unwrap(), b"original stem");
}
