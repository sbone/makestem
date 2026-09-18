use clap::{ArgAction, Parser};
use indicatif::{ProgressBar, ProgressStyle};
use makestem::inspect::inspect_audio;
use makestem::pipeline::{Event, Pipeline, Product, Reporter, prepare_model};
use serde_json::json;
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::Duration;

struct TerminalReporter(Option<ProgressBar>);

struct JsonReporter;

impl Reporter for JsonReporter {
    fn report(&mut self, event: Event) {
        let value = match event {
            Event::MetadataDetected(detail) => {
                json!({ "type": "metadata_detected", "detail": detail })
            }
            Event::StageStarted(label) => json!({ "type": "stage_started", "label": label }),
            Event::StageProgress { detail, percent } => {
                json!({ "type": "stage_progress", "detail": detail, "percent": percent })
            }
            Event::StageCompleted(label) => json!({ "type": "stage_completed", "label": label }),
        };
        println!("{value}");
        let _ = io::stdout().flush();
    }
}

impl TerminalReporter {
    fn new() -> Self {
        Self(None)
    }

    fn clear(&mut self) {
        if let Some(spinner) = self.0.take() {
            spinner.finish_and_clear();
        }
    }
}

impl Reporter for TerminalReporter {
    fn report(&mut self, event: Event) {
        match event {
            Event::MetadataDetected(detail) => {
                self.clear();
                eprintln!("✓ {detail} detected and will be preserved on output tracks");
            }
            Event::StageStarted(label) => {
                self.clear();
                let spinner = ProgressBar::new_spinner();
                spinner.set_style(ProgressStyle::with_template("{spinner:.cyan} {msg}").unwrap());
                spinner.enable_steady_tick(Duration::from_millis(90));
                spinner.set_message(label);
                self.0 = Some(spinner);
            }
            Event::StageProgress { detail, percent } => {
                if let Some(progress) = self.0.as_ref() {
                    if let Some(percent) = percent {
                        progress.set_length(100);
                        progress.set_position(percent);
                        progress.set_style(
                            ProgressStyle::with_template("{bar:24.cyan/dim} {pos:>3}% {msg}")
                                .unwrap()
                                .progress_chars("━━╸"),
                        );
                    }
                    progress.set_message(detail);
                }
            }
            Event::StageCompleted(label) => {
                if let Some(spinner) = self.0.take() {
                    spinner.finish_with_message(format!("✓ {label}"));
                }
            }
        }
    }
}

#[derive(Parser, Debug)]
#[command(
    name = "makestem",
    version,
    about = "Create DJ-ready stems from a full mix"
)]
struct Cli {
    /// Inspect a track and print machine-readable JSON
    #[arg(long, hide = true)]
    inspect_json: bool,

    /// Stream machine-readable processing events
    #[arg(long, hide = true)]
    events_json: bool,

    /// Download and cache the audio-separation model
    #[arg(long, hide = true)]
    prepare_model: bool,

    /// Create only an acapella
    #[arg(short = 'a', long, action = ArgAction::SetTrue, conflicts_with = "instrumental")]
    acapella: bool,

    /// Create only an instrumental
    #[arg(short = 'i', long, action = ArgAction::SetTrue)]
    instrumental: bool,

    /// Replace existing requested output files
    #[arg(long, action = ArgAction::SetTrue)]
    replace: bool,

    /// Source audio file
    #[arg(value_name = "TRACK")]
    track: Option<PathBuf>,
}

fn main() {
    configure_process_group();
    let cli = Cli::parse();
    if cli.inspect_json {
        let track = require_track(cli.track.as_deref());
        match inspect_audio(track) {
            Ok(inspection) => println!("{}", serde_json::to_string(&inspection).unwrap()),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        return;
    }
    if cli.prepare_model {
        let mut reporter = JsonReporter;
        let result = prepare_model(&mut reporter);
        match result {
            Ok(path) => println!("{}", json!({ "type": "complete", "outputs": [path] })),
            Err(error) => {
                println!(
                    "{}",
                    json!({ "type": "error", "message": error.message, "guidance": error.guidance })
                );
                std::process::exit(1);
            }
        }
        return;
    }
    let track = require_track(cli.track.as_deref());
    let products = if cli.acapella {
        vec![Product::Acapella]
    } else if cli.instrumental {
        vec![Product::Instrumental]
    } else {
        vec![Product::Acapella, Product::Instrumental]
    };

    if cli.events_json {
        let mut reporter = JsonReporter;
        let result = run_pipeline(track, &products, cli.replace, &mut reporter);
        match result {
            Ok(outputs) => {
                println!("{}", json!({ "type": "complete", "outputs": outputs }));
            }
            Err(error) => {
                println!(
                    "{}",
                    json!({
                        "type": "error",
                        "message": error.message,
                        "guidance": error.guidance
                    })
                );
                std::process::exit(1);
            }
        }
        return;
    }

    println!("Makestem\n");
    let mut reporter = TerminalReporter::new();
    let result = run_pipeline(track, &products, cli.replace, &mut reporter);
    reporter.clear();

    match result {
        Ok(outputs) => {
            println!(
                "\nDone — created {} file{}:",
                outputs.len(),
                if outputs.len() == 1 { "" } else { "s" }
            );
            for output in outputs {
                println!("  {}", output.display());
            }
        }
        Err(error) => {
            eprintln!("\nCouldn’t finish: {}", error.message);
            if let Some(guidance) = error.guidance {
                eprintln!("\nTry this: {guidance}");
            }
            std::process::exit(1);
        }
    }
}

fn configure_process_group() {
    #[cfg(unix)]
    if std::env::var_os("MAKESTEM_PROCESS_GROUP").is_some() {
        // The Mac app uses a dedicated process group so cancellation reaches
        // Makestem and its active Demucs/FFmpeg descendants together.
        unsafe {
            libc::setpgid(0, 0);
        }
    }
}

fn require_track(track: Option<&std::path::Path>) -> &std::path::Path {
    track.unwrap_or_else(|| {
        eprintln!("A source track is required.");
        std::process::exit(2);
    })
}

fn run_pipeline(
    track: &std::path::Path,
    products: &[Product],
    replace: bool,
    reporter: &mut impl Reporter,
) -> makestem::pipeline::Result<Vec<PathBuf>> {
    reporter.report(Event::StageStarted("Checking required tools".to_owned()));
    Pipeline::preflight()?;
    reporter.report(Event::StageCompleted("Checking required tools".to_owned()));

    reporter.report(Event::StageStarted("Inspecting source audio".to_owned()));
    let pipeline = Pipeline::new(track)?;
    reporter.report(Event::StageCompleted("Inspecting source audio".to_owned()));

    pipeline.run(products, replace, reporter)
}
