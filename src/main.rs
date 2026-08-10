use clap::{ArgAction, Parser};
use indicatif::{ProgressBar, ProgressStyle};
use serde_json::json;
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::Duration;
use stemcraft::inspect::inspect_audio;
use stemcraft::pipeline::{Event, Pipeline, Product, Reporter};

struct TerminalReporter(Option<ProgressBar>);

struct JsonReporter;

impl Reporter for JsonReporter {
    fn report(&mut self, event: Event) {
        let value = match event {
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
    name = "stemcraft",
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

    /// Create only an acapella
    #[arg(short = 'a', long, action = ArgAction::SetTrue, conflicts_with = "instrumental")]
    acapella: bool,

    /// Create only an instrumental
    #[arg(short = 'i', long, action = ArgAction::SetTrue)]
    instrumental: bool,

    /// Source audio file
    #[arg(value_name = "TRACK")]
    track: PathBuf,
}

fn main() {
    let cli = Cli::parse();
    if cli.inspect_json {
        match inspect_audio(&cli.track) {
            Ok(inspection) => println!("{}", serde_json::to_string(&inspection).unwrap()),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        return;
    }
    let products = if cli.acapella {
        vec![Product::Acapella]
    } else if cli.instrumental {
        vec![Product::Instrumental]
    } else {
        vec![Product::Acapella, Product::Instrumental]
    };

    if cli.events_json {
        let mut reporter = JsonReporter;
        let result = run_pipeline(&cli.track, &products, &mut reporter);
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

    println!("Stemcraft\n");
    let mut reporter = TerminalReporter::new();
    let result = run_pipeline(&cli.track, &products, &mut reporter);
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

fn run_pipeline(
    track: &std::path::Path,
    products: &[Product],
    reporter: &mut impl Reporter,
) -> stemcraft::pipeline::Result<Vec<PathBuf>> {
    reporter.report(Event::StageStarted("Checking required tools".to_owned()));
    Pipeline::preflight()?;
    reporter.report(Event::StageCompleted("Checking required tools".to_owned()));

    reporter.report(Event::StageStarted("Inspecting source audio".to_owned()));
    let pipeline = Pipeline::new(track)?;
    reporter.report(Event::StageCompleted("Inspecting source audio".to_owned()));

    pipeline.run(products, reporter)
}
