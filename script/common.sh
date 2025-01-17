#!/bin/bash

# This file contains commonly used BASH functions for scripting in canvas-lms,
# particularly script/canvas_update and script/rebase_canvas_and_plugins . As such,
# *be careful* when you modify these functions as doing so will impact multiple
# scripts that likely aren't used or tested in continuous integration builds.

BOLD="$(tput bold)"
NORMAL="$(tput sgr0)"

function create_log_file {
  if [ ! -f "$LOG" ]; then
    echo "" > "$LOG"
  fi
}

function echo_console_and_log {
  echo "$1" |tee -a "$LOG"
}

function print_results {
  exit_code=$?
  set +e

  if [ "${exit_code}" == "0" ]; then
    echo ""
    echo_console_and_log "  \o/ Success!"
  else
    echo ""
    echo_console_and_log "  /o\ Something went wrong. Check ${LOG} for details."
  fi

  exit ${exit_code}
}

function ensure_in_canvas_root_directory {
  if ! is_canvas_root; then
    echo "Please run from a Canvas root directory"
    exit 0
  fi
}

function is_canvas_root {
  CANVAS_IN_README=$(head -1 README.md 2>/dev/null | grep 'Canvas LMS')
  [[ "$CANVAS_IN_README" != "" ]] && is_git_dir
  return $?
}

function is_git_dir {
  [ "$(basename "$(git rev-parse --show-toplevel)")" == "$(basename "$(pwd)")" ]
}

# Parameter: the name of the script calling this function
function intro_message {
  script_name="$1"
  echo "Bringing Canvas up to date ..."
  echo "  Log file is $LOG"

  echo >>"$LOG"
  echo "-----------------------------" >>"$LOG"
  echo "$1 ($(date)):" >>"$LOG"
  echo "-----------------------------" >>"$LOG"
}

function build_images {
  message 'Building docker images...'
  if [[ "$(uname)" == 'Linux' && -z "${CANVAS_SKIP_DOCKER_USERMOD:-}" ]]; then
    _canvas_lms_track docker-compose build --pull --build-arg USER_ID=$(id -u)
  else
    _canvas_lms_track docker-compose build --pull
  fi
}

function check_gemfile {
  if [[ -e Gemfile.lock ]]; then
    message \
'For historical reasons, the Canvas Gemfile.lock is not tracked by git. We may
need to remove it before we can install gems, to prevent conflicting dependency
errors.'
    confirm_command 'rm -f Gemfile.lock' || true
  fi

  # Fixes 'error while trying to write to `/usr/src/app/Gemfile.lock`'
  if ! docker-compose run --no-deps --rm web touch Gemfile.lock; then
    message \
"The 'docker' user is not allowed to write to Gemfile.lock. We need write
permissions so we can install gems."
    touch Gemfile.lock
    confirm_command 'chmod a+rw Gemfile.lock' || true
  fi
}

function build_assets {
  message "Building assets..."
  _canvas_lms_track docker-compose run --rm web ./script/install_assets.sh -c bundle
  _canvas_lms_track docker-compose run --rm web ./script/install_assets.sh -c yarn
  _canvas_lms_track docker-compose run --rm web ./script/install_assets.sh -c compile
}

function database_exists {
  docker-compose run --rm web \
    bundle exec rails runner 'ActiveRecord::Base.connection' &> /dev/null
}

function create_db {
  if ! docker-compose run --no-deps --rm web touch db/structure.sql; then
    message \
"The 'docker' user is not allowed to write to db/structure.sql. We need write
permissions so we can run migrations."
    touch db/structure.sql
    confirm_command 'chmod a+rw db/structure.sql' || true
  fi

  if database_exists; then
    message \
'An existing database was found.

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
This script will destroy ALL EXISTING DATA if it continues
If you want to migrate the existing database, use docker_dev_update.sh
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!'
    message 'About to run "bundle exec rake db:drop"'
    if [[ -z "${JENKINS}" ]]; then
      prompt "type NUKE in all caps: " nuked
      [[ ${nuked:-n} == 'NUKE' ]] || exit 1
    fi
    _canvas_lms_track docker-compose run --rm web bundle exec rake db:drop
  fi

  message "Creating new database"
  _canvas_lms_track docker-compose run --rm web \
    bundle exec rake db:create
  # initial_setup runs db:migrate for development
  _canvas_lms_track docker-compose run -e TELEMETRY_OPT_IN --rm web \
    bundle exec rake db:initial_setup
  # Rails db:migrate only runs on development by default
  # https://discuss.rubyonrails.org/t/db-drop-create-migrate-behavior-with-rails-env-development/74435
  _canvas_lms_track docker-compose run --rm web \
    bundle exec rake db:migrate RAILS_ENV=test
}


function bundle_install {
  echo_console_and_log "  Installing gems (bundle install) ..."
  rm -f Gemfile.lock* >/dev/null 2>&1
  run_command bundle install >>"$LOG" 2>&1
}

function bundle_install_with_check {
  echo_console_and_log "  Checking your gems (bundle check) ..."
  if run_command bundle check >>"$LOG" 2>&1 ; then
    echo_console_and_log "  Gems are up to date, no need to bundle install ..."
  else
    bundle_install
  fi
}

function rake_db_migrate_dev_and_test {
  echo_console_and_log "  Migrating development DB ..."
  run_command bundle exec rake db:migrate RAILS_ENV=development >>"$LOG" 2>&1
  echo_console_and_log "  Migrating test DB ..."
  run_command bundle exec rake db:migrate RAILS_ENV=test >>"$LOG" 2>&1
}

function install_node_packages {
  echo_console_and_log "  Installing Node packages ..."
  run_command bundle exec rake js:yarn_install >>"$LOG" 2>&1
}

function compile_assets {
  echo_console_and_log "  Compiling assets (css and js only, no docs or styleguide) ..."
  run_command bundle exec rake canvas:compile_assets_dev >>"$LOG" 2>&1
}

# If DOCKER var set true, run with docker-compose
function run_command {
  if [ "${DOCKER:-}" == 'y' ]; then
    docker-compose run --rm web "$@"
  else
    "$@"
  fi
}

function _canvas_lms_track {
  command="$@"
  if type _inst_telemetry >/dev/null 2>&1 &&  _canvas_lms_telemetry_enabled; then
    _inst_telemetry $command
  else
    $command
  fi
}

function _canvas_lms_telemetry_enabled() {
  if [[ ${TELEMETRY_OPT_IN-n} == 'y' ]];
  then
    return 0
  fi
  return 1
}

function prompt {
  read -r -p "$1 " "$2"
}

function message {
  echo ''
  echo "$BOLD> $*$NORMAL"
}

function confirm_command {
  if [ -z "${JENKINS-}" ]; then
    prompt "OK to run '$*'? [y/n]" confirm
    [[ ${confirm:-n} == 'y' ]] || return 1
  fi
  eval "$*"
}
