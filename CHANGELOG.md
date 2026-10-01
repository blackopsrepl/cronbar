# Changelog

All notable changes to this project will be documented in this file. See [commit-and-tag-version](https://github.com/absolute-version/commit-and-tag-version) for commit guidelines.

## [0.1.1](https://github.com/blackopsrepl/cronbar/compare/v0.1.0...v0.1.1) (2026-10-01)

### Features

* **branding:** introduce Tick the clockwork schedule keeper 0304bf6

### Bug Fixes

* **collector:** exclude the system crontab documentation legend f3d4eb1
* **collector:** separate users on special system schedules 01c9fa1

## 0.1.0 (2026-10-01)

### Features

* **core:** collect cron and anacron surfaces into one runnable snapshot fbbad4d
* **packaging:** ship desktop wiring and operating guidance 1d43cce
* **panel:** add the native scheduled-job inspector f873bba

### Bug Fixes

* **runner:** persist a boolean dry-run flag 31baf3b

### test

* **core:** cover surface collection, manual runs, and the run gate c6809b3
* **gate:** clean up the owned credential fixture root e58cdb8
* **integration:** exercise cached chips and shell placement 0e66e16

### build

* **release:** add checked installation and conventional version tooling 30c97ae

### ci

* **release:** gate and publish tags on both forges 171f043
