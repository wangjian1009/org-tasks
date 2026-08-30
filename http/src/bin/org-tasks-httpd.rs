use clap::Parser;

#[tokio::main]
async fn main() {
    let cli = org_tasks_http::server::Cli::parse();
    let log_level = match &cli.command {
        org_tasks_http::server::Command::Serve(args) => args.log_level,
        org_tasks_http::server::Command::Check(_) => org_tasks_http::server::LogLevel::Info,
    };
    org_tasks_http::server::init_logging(log_level);
    if let Err(error) = org_tasks_http::server::run(cli.command).await {
        eprintln!("org-tasks-httpd: {error}");
        std::process::exit(1);
    }
}
