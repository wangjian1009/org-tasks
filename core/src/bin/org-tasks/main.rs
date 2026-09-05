mod cli;

#[tokio::main]
async fn main() {
    if let Err(error) = cli::run().await {
        eprintln!("org-tasks: {error}");
        std::process::exit(1);
    }
}
