#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "pathname"
require "shellwords"
require "tmpdir"
require "uri"

DEFAULTS = {
  allow_existing_repo: false,
  asset_name: nil,
  binary_name: nil,
  binary_path: nil,
  command_name: nil,
  config: nil,
  desc: nil,
  force: false,
  formula: nil,
  homepage: nil,
  html_launcher: true,
  install_as: nil,
  install_layout: "bin",
  kind: "auto",
  license: nil,
  libexec_rename_glob: nil,
  libexec_rename_to: nil,
  publish: false,
  repo: nil,
  run_workflow: false,
  schedule: "17 */6 * * *",
  tap_owner: nil,
  tap_repo: nil,
  test_arg: "--help",
  test_match: nil,
  update_only: false,
  visibility: "public",
  wrapper_interpreter: nil,
  workdir: Dir.pwd
}.freeze

class Failure < StandardError; end

def say(message)
  warn "==> #{message}"
end

def fail!(message)
  raise Failure, message
end

def symbolize_hash(hash)
  hash.each_with_object({}) { |(key, value), memo| memo[key.to_sym] = value }
end

def load_options
  options = DEFAULTS.dup
  seen = {}

  setter = lambda do |key, value|
    options[key] = value
    seen[key] = true
  end

  OptionParser.new do |parser|
    parser.banner = "Usage: scaffold_brew_tap.rb --repo OWNER/REPO [options]"
    parser.on("--repo REPO", "Upstream GitHub repo or URL") { |value| setter.call(:repo, value) }
    parser.on("--config PATH", "Load generated tap config") { |value| setter.call(:config, value) }
    parser.on("--workdir DIR", "Directory where the local tap folder is created") { |value| setter.call(:workdir, value) }
    parser.on("--formula NAME", "Formula name") { |value| setter.call(:formula, value) }
    parser.on("--tap-owner OWNER", "GitHub owner for the tap repo") { |value| setter.call(:tap_owner, value) }
    parser.on("--tap-repo NAME", "Tap repo name") { |value| setter.call(:tap_repo, value) }
    parser.on("--kind KIND", "auto, binary, or static") { |value| setter.call(:kind, value) }
    parser.on("--binary-name NAME", "Executable basename inside an archive") { |value| setter.call(:binary_name, value) }
    parser.on("--binary-path PATH", "Executable path inside an archive") { |value| setter.call(:binary_path, value) }
    parser.on("--install-as NAME", "Command name installed into Homebrew bin") { |value| setter.call(:install_as, value) }
    parser.on("--install-layout LAYOUT", "bin or libexec-wrapper") { |value| setter.call(:install_layout, value) }
    parser.on("--asset-name NAME", "Static release asset name") { |value| setter.call(:asset_name, value) }
    parser.on("--desc TEXT", "Formula description") { |value| setter.call(:desc, value) }
    parser.on("--homepage URL", "Formula homepage") { |value| setter.call(:homepage, value) }
    parser.on("--license SPDX", "Formula license") { |value| setter.call(:license, value) }
    parser.on("--libexec-rename GLOB=NAME", "Rename a libexec file matching GLOB to NAME") do |value|
      glob, name = value.split("=", 2)
      fail!("expected --libexec-rename GLOB=NAME") if glob.nil? || glob.empty? || name.nil? || name.empty?

      setter.call(:libexec_rename_glob, glob)
      setter.call(:libexec_rename_to, name)
    end
    parser.on("--test-arg ARG", "Argument for binary formula smoke test") { |value| setter.call(:test_arg, value) }
    parser.on("--test-match TEXT", "Expected smoke-test output; use {version} for formula version") { |value| setter.call(:test_match, value) }
    parser.on("--schedule CRON", "Updater workflow cron") { |value| setter.call(:schedule, value) }
    parser.on("--visibility VALUE", "public or private") { |value| setter.call(:visibility, value) }
    parser.on("--wrapper-interpreter FORMULA", "Use formula interpreter in libexec wrapper, e.g. python@3.14") { |value| setter.call(:wrapper_interpreter, value) }
    parser.on("--publish", "Create/push the GitHub tap repo") { setter.call(:publish, true) }
    parser.on("--no-publish", "Do not create/push the GitHub tap repo") { setter.call(:publish, false) }
    parser.on("--run-workflow", "Trigger and watch the updater workflow after publishing") { setter.call(:run_workflow, true) }
    parser.on("--no-html-launcher", "Do not add a local server wrapper for HTML assets") { setter.call(:html_launcher, false) }
    parser.on("--allow-existing-repo", "Allow pushing to an existing GitHub repo") { setter.call(:allow_existing_repo, true) }
    parser.on("--force", "Overwrite an existing local tap folder") { setter.call(:force, true) }
    parser.on("--update-only", "Only update the formula in an existing generated tap") { setter.call(:update_only, true) }
  end.parse!

  if options[:config]
    config_path = Pathname.new(options[:config]).expand_path
    config = symbolize_hash(JSON.parse(config_path.read))
    options = DEFAULTS.merge(config).merge(seen.each_with_object({}) { |(key, _), memo| memo[key] = options[key] })
    options[:config] = config_path.to_s
  end

  options
end

def run_capture!(*cmd, chdir: nil)
  spawn_options = {}
  spawn_options[:chdir] = chdir if chdir
  stdout, stderr, status = Open3.capture3(*cmd, spawn_options)
  return stdout if status.success?

  fail!("command failed: #{cmd.shelljoin}\n#{stderr}#{stdout}")
end

def run!(*cmd, chdir: nil)
  spawn_options = {}
  spawn_options[:chdir] = chdir if chdir
  system(*cmd, spawn_options)
  fail!("command failed: #{cmd.shelljoin}") unless $?.success?
end

def command_available?(command)
  _stdout, _stderr, status = Open3.capture3("sh", "-c", "command -v #{Shellwords.escape(command)}")
  status.success?
end

def github_get(url, redirects: 5, &block)
  fail!("too many redirects for #{url}") if redirects.negative?

  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/vnd.github+json"
  request["User-Agent"] = "brew-tap-publisher"
  if ENV["GITHUB_TOKEN"]&.length&.positive? && ["api.github.com", "github.com"].include?(uri.host)
    request["Authorization"] = "Bearer #{ENV.fetch("GITHUB_TOKEN")}"
  end

  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request) do |response|
      case response
      when Net::HTTPSuccess
        return block.call(response)
      when Net::HTTPRedirection
        location = response["location"]
        fail!("redirect without location for #{url}") if location.nil? || location.empty?

        return github_get(location, redirects: redirects - 1, &block)
      else
        fail!("GET #{url} failed: #{response.code} #{response.message}")
      end
    end
  end
end

def fetch_json(url)
  github_get(url) { |response| JSON.parse(response.body) }
end

def download_to(url, path)
  if command_available?("curl")
    run!("curl", "-fsSL", "-o", path, url)
    return
  end

  github_get(url) do |response|
    File.open(path, "wb") { |file| response.read_body { |chunk| file.write(chunk) } }
  end
end

def normalize_repo(value)
  fail!("provide --repo OWNER/REPO") if value.nil? || value.strip.empty?

  repo = value.strip
              .sub(%r{\Ahttps://github\.com/}i, "")
              .sub(%r{\Agit@github\.com:}i, "")
              .sub(/\.git\z/i, "")
              .sub(%r{/releases.*\z}i, "")
              .sub(%r{/tree/.*\z}i, "")
  parts = repo.split("/")
  fail!("expected GitHub repo as OWNER/REPO, got #{value.inspect}") unless parts.length >= 2

  "#{parts[0]}/#{parts[1]}"
end

def sanitize_name(value)
  value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
end

def formula_class_name(formula)
  formula.split("-").map { |part| part[0].upcase + part[1..] }.join
end

def ruby_string(value)
  value.to_s.inspect
end

def shell_string(value)
  value.to_s.gsub("\\", "\\\\\\").gsub('"', '\"')
end

def indent_code(code, spaces = 4)
  prefix = " " * spaces
  code.lines.map { |line| line.strip.empty? ? "\n" : "#{prefix}#{line.strip}\n" }.join.rstrip
end

def asset_url(asset)
  asset["browser_download_url"] || asset["url"] || fail!("asset #{asset["name"]} has no download URL")
end

def relevant_assets(assets)
  assets.reject { |asset| asset.fetch("name").match?(/checksum|sha256|sha512/i) }
end

def asset_named(assets, name)
  assets.find { |asset| asset.fetch("name") == name } || fail!("missing release asset #{name.inspect}")
end

def sha256_for(asset)
  digest = asset["digest"].to_s
  return digest.delete_prefix("sha256:") if digest.start_with?("sha256:")

  Dir.mktmpdir do |dir|
    path = File.join(dir, asset.fetch("name"))
    say "Downloading #{asset.fetch("name")} to compute SHA256"
    download_to(asset_url(asset), path)
    Digest::SHA256.file(path).hexdigest
  end
end

def archive_asset?(asset)
  asset.fetch("name").match?(/\.(tar\.gz|tgz|zip)\z/i)
end

def static_asset?(asset)
  !archive_asset?(asset)
end

def darwin_asset(assets, arch)
  arch_regex = arch == :arm ? /(aarch64|arm64)/i : /(amd64|x86_64|x64)/i
  candidates = relevant_assets(assets).select do |asset|
    name = asset.fetch("name")
    archive_asset?(asset) && name.match?(/darwin|macos|mac/i) && name.match?(arch_regex)
  end
  candidates.sort_by { |asset| [asset.fetch("name").include?("no-plugin") ? 1 : 0, asset.fetch("name")] }.first
end

def infer_kind(options, assets)
  return options[:kind] unless options[:kind] == "auto"
  return "static" if options[:asset_name]
  return "binary" if darwin_asset(assets, :arm) || darwin_asset(assets, :intel)

  static_assets = relevant_assets(assets).select { |asset| static_asset?(asset) }
  return "static" if static_assets.length == 1 || static_assets.any? { |asset| asset.fetch("name") == "management.html" }

  fail!("could not infer formula kind; rerun with --kind binary or --kind static")
end

def list_archive_entries(path)
  name = File.basename(path)
  if name.match?(/\.(tar\.gz|tgz)\z/i)
    run_capture!("tar", "-tzf", path).lines.map(&:strip)
  elsif name.match?(/\.zip\z/i)
    run_capture!("unzip", "-Z1", path).lines.map(&:strip)
  else
    fail!("unsupported archive type: #{name}")
  end
end

def infer_binary_path(asset, binary_name, formula)
  Dir.mktmpdir do |dir|
    path = File.join(dir, asset.fetch("name"))
    say "Downloading #{asset.fetch("name")} to inspect archive contents"
    download_to(asset_url(asset), path)
    entries = list_archive_entries(path).reject { |entry| entry.end_with?("/") }
    return entries.find { |entry| File.basename(entry) == binary_name } if binary_name

    candidates = entries.reject do |entry|
      base = File.basename(entry)
      ext = File.extname(base)
      base.start_with?(".") ||
        base.match?(/\A(license|readme|changelog|notice|config|checksums?)(\..*)?\z/i) ||
        [".md", ".txt", ".yaml", ".yml", ".json", ".toml", ".html", ".xml"].include?(ext.downcase)
    end

    preferred = candidates.find { |entry| sanitize_name(File.basename(entry)) == formula }
    return preferred if preferred
    return candidates.first if candidates.length == 1

    fail!("could not infer binary path from archive; rerun with --binary-name NAME")
  end
end

def repo_metadata(repo)
  fetch_json("https://api.github.com/repos/#{repo}")
end

def release_metadata(repo)
  fetch_json("https://api.github.com/repos/#{repo}/releases/latest")
end

def current_gh_user
  JSON.parse(run_capture!("gh", "api", "user")).fetch("login")
rescue Failure
  fail!("gh must be installed and authenticated to infer tap owner; run gh auth login or pass --tap-owner")
end

def generated_config(options)
  keys = %i[
    asset_name binary_name binary_path desc formula homepage html_launcher install_as install_layout kind
    libexec_rename_glob libexec_rename_to license repo schedule tap_owner tap_repo test_arg
    test_match visibility wrapper_interpreter
  ]
  keys.each_with_object({}) { |key, memo| memo[key] = options[key] unless options[key].nil? }
end

def formula_path(tap_path, formula)
  tap_path.join("Formula", "#{formula}.rb")
end

def tap_token(options)
  options.fetch(:tap_repo).sub(/\Ahomebrew-/, "")
end

def update_workflow(schedule)
  <<~YAML
    name: Update Formula

    on:
      workflow_dispatch:
      schedule:
        - cron: #{schedule.inspect}

    permissions:
      contents: write

    jobs:
      update:
        runs-on: ubuntu-latest
        steps:
          - name: Checkout
            uses: actions/checkout@v7

          - name: Setup Ruby
            uses: ruby/setup-ruby@v1
            with:
              ruby-version: "3.3"

          - name: Update formula
            run: ruby scripts/brew_tap_publisher.rb --config .github/brew-tap-publisher.json --update-only
            env:
              GITHUB_TOKEN: ${{ github.token }}

          - name: Commit update
            run: |
              if git diff --quiet; then
                echo "Formula already current."
                exit 0
              fi

              git config user.name "github-actions[bot]"
              git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
              git add Formula .github/brew-tap-publisher.json
              git commit -m "Update formula"
              git push
  YAML
end

def readme_content(options, upstream_version)
  owner = options.fetch(:tap_owner)
  formula = options.fetch(:formula)
  upstream = options.fetch(:repo)
  tap = "#{owner}/#{tap_token(options)}"
  <<~MD
    # Homebrew Tap for #{formula}

    Personal Homebrew tap for [#{upstream}](https://github.com/#{upstream}).

    ## Install

    ```sh
    brew install #{tap}/#{formula}
    ```

    Seeded from upstream release `v#{upstream_version}`.

    ## Updating

    `.github/workflows/update-formula.yml` checks the latest upstream GitHub release on a schedule and commits formula updates when a new release is available.
  MD
end

def binary_formula(options, release, repo_info)
  formula = options.fetch(:formula)
  class_name = formula_class_name(formula)
  version = release.fetch("tag_name").delete_prefix("v")
  assets = release.fetch("assets")
  arm_asset = darwin_asset(assets, :arm)
  intel_asset = darwin_asset(assets, :intel)
  fail!("missing macOS release archive") unless arm_asset || intel_asset

  inspect_asset = arm_asset || intel_asset
  binary_path = options[:binary_path] || infer_binary_path(inspect_asset, options[:binary_name], formula)
  options[:binary_path] = binary_path
  install_as = options[:install_as] || formula
  install_layout = options[:install_layout]
  fail!("--install-layout must be bin or libexec-wrapper") unless %w[bin libexec-wrapper].include?(install_layout)

  desc = options[:desc] || repo_info["description"] || "GitHub release binary"
  homepage = options[:homepage] || repo_info["html_url"] || "https://github.com/#{options.fetch(:repo)}"
  license = options[:license] || repo_info.dig("license", "spdx_id")
  license_line = license && license != "NOASSERTION" ? "  license #{ruby_string(license)}\n" : ""
  dependencies = []
  dependencies << "  depends_on :macos"
  dependencies << "  depends_on arch: :arm64" if arm_asset && !intel_asset
  dependencies << "  depends_on arch: :x86_64" if intel_asset && !arm_asset
  dependencies << "  depends_on #{ruby_string(options[:wrapper_interpreter])}" if install_layout == "libexec-wrapper" && options[:wrapper_interpreter]
  url_block = if arm_asset && intel_asset
                <<~RUBY.rstrip
                  if Hardware::CPU.arm?
                    url #{ruby_string(asset_url(arm_asset))}
                    sha256 #{ruby_string(sha256_for(arm_asset))}
                  else
                    url #{ruby_string(asset_url(intel_asset))}
                    sha256 #{ruby_string(sha256_for(intel_asset))}
                  end
                RUBY
              elsif arm_asset
                <<~RUBY.rstrip
                  url #{ruby_string(asset_url(arm_asset))}
                  sha256 #{ruby_string(sha256_for(arm_asset))}
                RUBY
              else
                <<~RUBY.rstrip
                  url #{ruby_string(asset_url(intel_asset))}
                  sha256 #{ruby_string(sha256_for(intel_asset))}
                RUBY
              end

  install_body = if install_layout == "libexec-wrapper"
                   interpreter = options[:wrapper_interpreter]
                   exec_line = if interpreter
                                 "exec \"\#{Formula[#{ruby_string(interpreter)}].opt_bin}/python3\" \"\#{libexec}/#{binary_path}\" \"$@\""
                               else
                                 "exec \"\#{libexec}/#{binary_path}\" \"$@\""
                               end
                   rename_body = if options[:libexec_rename_glob] && options[:libexec_rename_to]
                                   <<~RUBY
                                     candidate = Dir[libexec/#{ruby_string(options[:libexec_rename_glob])}].first
                                     mv candidate, libexec/#{ruby_string(options[:libexec_rename_to])} if candidate && File.basename(candidate) != #{ruby_string(options[:libexec_rename_to])}
                                   RUBY
                                 else
                                   ""
                                 end
                   <<~RUBY.rstrip
                     libexec.install Dir["*"]
                  #{rename_body.rstrip}
                     (bin/#{ruby_string(install_as)}).write <<~EOS
                       #!/bin/bash
                       set -euo pipefail
                       #{exec_line}
                     EOS
                     chmod 0555, bin/#{ruby_string(install_as)}
                   RUBY
                 else
                   <<~RUBY.rstrip
                     bin.install #{ruby_string(binary_path)} => #{ruby_string(install_as)}
                     pkgshare.install "config.example.yaml" if File.exist?("config.example.yaml")
                     doc.install "README.md" if File.exist?("README.md")
                     doc.install "README_CN.md" if File.exist?("README_CN.md")
                     prefix.install "LICENSE" if File.exist?("LICENSE")
                   RUBY
                 end

  test_arg = options[:test_arg]
  test_line = if test_arg && test_arg != "none"
                test_match = options[:test_match] == "{version}" ? version : (options[:test_match] || File.basename(binary_path))
                "    output = shell_output(\"\#{bin}/#{install_as} #{test_arg} 2>&1\")\n    assert_match #{ruby_string(test_match)}, output\n"
              else
                "    assert_path_exists bin/#{ruby_string(install_as)}\n"
              end

  <<~RUBY
    class #{class_name} < Formula
      desc #{ruby_string(desc)}
      homepage #{ruby_string(homepage)}
      version #{ruby_string(version)}
    #{license_line}
    #{dependencies.join("\n")}

    #{url_block.lines.map { |line| "  #{line}" }.join.rstrip}

      livecheck do
        url #{ruby_string("https://github.com/#{options.fetch(:repo)}/releases/latest")}
        strategy :github_latest
      end

      def install
    #{indent_code(install_body)}
      end

      test do
    #{test_line.rstrip}
      end
    end
  RUBY
end

def static_formula(options, release, repo_info)
  formula = options.fetch(:formula)
  class_name = formula_class_name(formula)
  version = release.fetch("tag_name").delete_prefix("v")
  assets = release.fetch("assets")
  static_assets = relevant_assets(assets).select { |asset| static_asset?(asset) }
  asset = if options[:asset_name]
            asset_named(assets, options[:asset_name])
          elsif (management = static_assets.find { |candidate| candidate.fetch("name") == "management.html" })
            management
          elsif static_assets.length == 1
            static_assets.first
          else
            fail!("could not infer static asset; rerun with --asset-name NAME")
          end

  asset_name = asset.fetch("name")
  command = options[:install_as] || formula
  desc = options[:desc] || repo_info["description"] || "Static GitHub release asset"
  homepage = options[:homepage] || repo_info["html_url"] || "https://github.com/#{options.fetch(:repo)}"
  license = options[:license] || repo_info.dig("license", "spdx_id")
  license_line = license && license != "NOASSERTION" ? "  license #{ruby_string(license)}\n" : ""
  html = asset_name.end_with?(".html") && options[:html_launcher]
  depends = html ? "\n  depends_on \"python@3.14\"\n" : ""
  url_line = static_asset?(asset) ? "  url #{ruby_string(asset_url(asset))},\n      using: :nounzip" : "  url #{ruby_string(asset_url(asset))}"

  raw_install_body = if html
                   <<~RUBY.chomp
                     (share/#{ruby_string(formula)}).install #{ruby_string(asset_name)}

                     (bin/#{ruby_string(command)}).write <<~EOS
                       #!/bin/bash
                       set -euo pipefail

                       case "${1:-}" in
                         --version|-v)
                           echo "#{version}"
                           exit 0
                           ;;
                         --path)
                           echo "\#{opt_share}/#{formula}/#{asset_name}"
                           exit 0
                           ;;
                         --help|-h)
                           cat <<'HELP'
                       Usage: #{command} [--port PORT]
                              #{command} --path
                              #{command} --version

                       Serves #{asset_name} on localhost.
                       HELP
                           exit 0
                           ;;
                       esac

                       port="${BREW_TAP_PUBLISHER_PORT:-5173}"
                       if [[ "${1:-}" == "--port" ]]; then
                         if [[ -z "${2:-}" ]]; then
                           echo "missing value for --port" >&2
                           exit 2
                         fi
                         port="$2"
                         shift 2
                       fi

                       if [[ $# -gt 0 ]]; then
                         echo "unknown argument: $1" >&2
                         exit 2
                       fi

                       root="\#{opt_share}/#{formula}"
                       url="http://127.0.0.1:${port}/#{asset_name}"

                       echo "Serving #{formula} #{version} at ${url}"
                       echo "Press Ctrl-C to stop."
                       command -v open >/dev/null 2>&1 && open "${url}" >/dev/null 2>&1 || true
                       cd "${root}"
                       exec "\#{Formula["python@3.14"].opt_bin}/python3" -m http.server "${port}" --bind 127.0.0.1
                     EOS
                     chmod 0555, bin/#{ruby_string(command)}
                   RUBY
                 else
                   "(share/#{ruby_string(formula)}).install #{ruby_string(asset_name)}"
                 end

  install_body = raw_install_body.lines.map { |line| line.strip.empty? ? "\n" : "    #{line}" }.join.rstrip
  raw_test_body = if html
                    "assert_path_exists share/#{ruby_string("#{formula}/#{asset_name}")}\nassert_equal version.to_s, shell_output(\"\#{bin}/#{command} --version\").strip"
                  else
                    "assert_path_exists share/#{ruby_string("#{formula}/#{asset_name}")}"
                  end
  test_body = raw_test_body.lines.map { |line| "    #{line}" }.join.rstrip

  <<~RUBY
    class #{class_name} < Formula
      desc #{ruby_string(desc)}
      homepage #{ruby_string(homepage)}
    #{url_line}
      version #{ruby_string(version)}
      sha256 #{ruby_string(sha256_for(asset))}
    #{license_line}#{depends}
      livecheck do
        url #{ruby_string("https://github.com/#{options.fetch(:repo)}/releases/latest")}
        strategy :github_latest
      end

      def install
    #{install_body}
      end

      test do
    #{test_body}
      end
    end
  RUBY
end

def write_tap(options, formula_content, upstream_version)
  tap_path = if options[:update_only]
               Pathname.new(options.fetch(:workdir)).expand_path
             else
               Pathname.new(options.fetch(:workdir)).expand_path.join(options.fetch(:tap_repo))
             end
  if tap_path.exist?
    if options[:force]
      FileUtils.rm_rf(tap_path)
    elsif !options[:update_only]
      fail!("local tap folder already exists: #{tap_path}; rerun with --force or choose --tap-repo")
    end
  end

  FileUtils.mkdir_p(tap_path.join("Formula"))
  FileUtils.mkdir_p(tap_path.join(".github", "workflows"))
  FileUtils.mkdir_p(tap_path.join("scripts"))

  formula_path(tap_path, options.fetch(:formula)).write(formula_content)
  tap_path.join("README.md").write(readme_content(options, upstream_version)) unless options[:update_only]
  tap_path.join(".github", "workflows", "update-formula.yml").write(update_workflow(options.fetch(:schedule))) unless options[:update_only]
  tap_path.join(".github", "brew-tap-publisher.json").write(JSON.pretty_generate(generated_config(options)) + "\n")
  tap_path.join("scripts", "brew_tap_publisher.rb").write(File.read(__FILE__)) unless options[:update_only]
  tap_path
end

def validate_formula!(tap_path, formula)
  run!("ruby", "-c", formula_path(tap_path, formula).to_s)
end

def repo_exists?(slug)
  _stdout, _stderr, status = Open3.capture3("gh", "repo", "view", slug, "--json", "nameWithOwner")
  status.success?
end

def ensure_git_commit(tap_path, message)
  unless tap_path.join(".git").exist?
    run!("git", "init", "-b", "main", chdir: tap_path.to_s)
  end
  run!("git", "add", "README.md", "Formula", ".github", "scripts", chdir: tap_path.to_s)
  _stdout, _stderr, status = Open3.capture3("git", "diff", "--cached", "--quiet", chdir: tap_path.to_s)
  return false if status.success?

  run!("git", "commit", "-m", message, chdir: tap_path.to_s)
  true
end

def publish_tap!(tap_path, options)
  slug = "#{options.fetch(:tap_owner)}/#{options.fetch(:tap_repo)}"
  if repo_exists?(slug)
    fail!("GitHub repo #{slug} already exists; rerun with --allow-existing-repo to push to it") unless options[:allow_existing_repo]

    remote_url = "https://github.com/#{slug}.git"
    remotes = run_capture!("git", "remote", chdir: tap_path.to_s).split
    if remotes.include?("origin")
      run!("git", "remote", "set-url", "origin", remote_url, chdir: tap_path.to_s)
    else
      run!("git", "remote", "add", "origin", remote_url, chdir: tap_path.to_s)
    end
    run!("git", "push", "-u", "origin", "main", chdir: tap_path.to_s)
  else
    visibility_flag = options.fetch(:visibility) == "private" ? "--private" : "--public"
    run!(
      "gh", "repo", "create", slug,
      visibility_flag,
      "--source=.",
      "--remote=origin",
      "--push",
      "--description", "Homebrew tap for #{options.fetch(:formula)}",
      chdir: tap_path.to_s
    )
  end

  return unless options[:run_workflow]

  run!("gh", "workflow", "run", "update-formula.yml", "--repo", slug)
  sleep 3
  run_id = JSON.parse(run_capture!("gh", "run", "list", "--repo", slug, "--workflow", "update-formula.yml", "--limit", "1", "--json", "databaseId")).first&.fetch("databaseId")
  run!("gh", "run", "watch", run_id.to_s, "--repo", slug, "--exit-status") if run_id
end

def finalize_options(options, repo_info, release)
  repo_name = options.fetch(:repo).split("/").last
  formula = sanitize_name(options[:formula] || repo_name)
  fail!("could not derive formula name; pass --formula NAME") if formula.empty?

  options[:formula] = formula
  options[:install_as] ||= formula
  options[:kind] = infer_kind(options, release.fetch("assets"))
  fail!("--kind must be auto, binary, or static") unless %w[binary static].include?(options[:kind])

  options[:tap_owner] ||= current_gh_user
  options[:tap_repo] ||= "homebrew-#{formula}"
  options[:homepage] ||= repo_info["html_url"] || "https://github.com/#{options.fetch(:repo)}"
  options[:desc] ||= repo_info["description"]
  options[:license] ||= repo_info.dig("license", "spdx_id")
  options
end

def main
  options = load_options
  options[:repo] = normalize_repo(options[:repo])

  say "Fetching upstream metadata for #{options[:repo]}"
  repo_info = repo_metadata(options[:repo])
  release = release_metadata(options[:repo])
  options = finalize_options(options, repo_info, release)

  say "Generating #{options[:kind]} formula #{options[:formula]} from #{release.fetch("tag_name")}"
  formula_content = if options[:kind] == "binary"
                      binary_formula(options, release, repo_info)
                    else
                      static_formula(options, release, repo_info)
                    end

  tap_path = write_tap(options, formula_content, release.fetch("tag_name").delete_prefix("v"))
  validate_formula!(tap_path, options.fetch(:formula))

  unless options[:update_only]
    say "Committing local tap at #{tap_path}"
    ensure_git_commit(tap_path, "Add #{options.fetch(:formula)} formula")
  end

  publish_tap!(tap_path, options) if options[:publish] && !options[:update_only]

  say "Tap ready: #{tap_path}"
  say "Install with: brew install #{options.fetch(:tap_owner)}/#{tap_token(options)}/#{options.fetch(:formula)}"
end

begin
  main
rescue Failure => e
  warn "error: #{e.message}"
  exit 1
end
