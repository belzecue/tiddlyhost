MAKEFLAGS+=--no-print-directory

# Show a list of available tasks
_help:
	@echo Available tasks:
	@grep '^[^_#\\$$[:space:]][^=/[:space:]]*:' Makefile | cut -d: -f1 | xargs -n1 echo ' make'

#----------------------------------------------------------

# On Mac my user's main group id is too low and I get this:
#   addgroup: The GID `20' is already in use.
# Fix it by setting a higher group id, e.g.:
#   GROUP_ID=501 make build-base
# The number shouldn't matter too much.
USER_ID ?= $(shell id -u)
GROUP_ID ?= $(shell id -g)

#----------------------------------------------------------

# The idea here is that I want to pin the base image in Dockerfile.base
# for reproducibility but also have an easy way to keep it updated when
# a new version is available.
#
RUBY_VER=3.3
RUBY_TAG=$(RUBY_VER)-slim

pull-ruby:
	$(D) pull ruby:$(RUBY_TAG)
	NO_COMMIT=1 bin/pin-digest.sh docker.io/library/ruby:$(RUBY_TAG) docker/Dockerfile.base "Newer ruby base image pulled from docker hub"

# Build base docker image
# (The build args are important here, the build will fail without them)
_build-base: cleanup
	$(DC) build --progress plain --no-cache --build-arg USER_ID=$(USER_ID) --build-arg GROUP_ID=$(GROUP_ID) app

# Use this if you're hacking on docker/Dockerfile.base and building repeatedly
fast-build-base:
	$(DC) build --progress plain --build-arg USER_ID=$(USER_ID) --build-arg GROUP_ID=$(GROUP_ID) app

build-base: _build-base push-base
	NO_COMMIT=1 bin/pin-digest.sh docker.io/sbaird/tiddlyhost-base:latest docker/Dockerfile.prod "Tiddlyhost base image rebuilt"

# To set up your environment right after doing a git clone
# Beware: This command runs `rails db:setup` which will clear out your local database
DB_VOL_MOUNT=docker/postgresql-data
APP_VOL_MOUNTS=docker/bundle docker/log docker/config docker/secrets node_modules docker/dotcache
rails-init: build-info js-math download-empty-prerelease gzip-core-js-files
	mkdir -p $(DB_VOL_MOUNT) $(APP_VOL_MOUNTS)
	$(DC) run --rm app bash -c "bin/bundle install && bin/rails yarn:install && bin/rails db:setup"

# Identical to the above but with an extra chown command since the user id in
# the container doesn't match the local user id when running in GitHub workflow
rails-init-ci:
	mkdir -p $(DB_VOL_MOUNT) $(APP_VOL_MOUNTS)
	sudo chown $(USER_ID):$(GROUP_ID) -R rails $(APP_VOL_MOUNTS)
	$(DC) run --rm app bash -c "bin/bundle install && bin/rails yarn:install && bin/rails db:setup"

#----------------------------------------------------------

docker/secrets:
	@mkdir -p $@

docker/secrets/master.key: docker/secrets
	@cp rails/config/master.key $@

docker/secrets/credentials.yml.enc: docker/secrets
	@cp rails/config/credentials.yml.enc $@

prod-secrets: docker/secrets/master.key docker/secrets/credentials.yml.enc

#----------------------------------------------------------

# Fun way to reuse the ansible templates to create local config
docker/%: ansible/playbooks/templates/docker/%.j2
	@mkdir -p $$(dirname $@)
	@env primary_host=tiddlyhost.local tiddlyspot_host=tiddlyspot.local \
	  python -c "import os,sys,jinja2; print(jinja2.Template(sys.stdin.read()).render(os.environ))" \
	  < $< > $@
	@echo $@ created using $<

local-nginx: docker/nginx-conf/app.conf docker/nginx-conf/commonconf
local-rails: docker/config/settings_local.yml

local-config: local-nginx local-rails

#----------------------------------------------------------

# Brings up the web container only and runs bash in it
run-base:
	-$(DC) run --rm --no-deps app bash

# Brings up the db and the web container and runs bash in the web container
shell:
	-$(DC) run --rm app bash

# Figure out if there's already a container running and use exec or run accordingly
EXEC_OR_RUN=$(shell [[ $$($(DC) ps --services --filter status=running | grep app ) ]] && echo 'exec' || echo 'run --rm')
D=docker
DC=docker-compose
DC_PROD=docker-compose -f docker-compose-prod.yml
DCC=-$(DC) $(EXEC_OR_RUN) app bash -c

join:
	$(DCC) bash

sandbox:
	$(DCC) 'bin/rails console --sandbox'

console:
	$(DCC) 'bin/rails console'

db-migrate:
	$(DCC) 'bin/rails db:migrate'

tmp-clear:
	$(DCC) 'bin/rails tmp:clear'

docker/log:
	mkdir -p docker/log

app-log: docker/log

#----------------------------------------------------------

# Start Tiddlyhost locally - app only, no container, no SSL
db-start:
	@$(DC) up --detach db

db-stop:
	$(DC) stop

rstart: db-start
	@cd rails && bundle install && rails s

rtest: db-start
	@cd rails && bundle install && rails t

#----------------------------------------------------------

# Start Tiddlyhost locally - containerized full stack with SSL
start: local-config cert app-log
	-$(DC) up

#----------------------------------------------------------

# Run bundle-install
bundle-install:
	@mkdir -p docker/bundle
	-$(DC) run --rm --no-deps app bash -c "bin/bundle install"

# Run bundle-update
bundle-update:
	-$(DC) run --rm --no-deps app bash -c "bin/bundle update --quiet"

# Run bundle-clean
bundle-clean:
	-$(DC) run --rm --no-deps app bash -c "bin/bundle clean"

# Run yarn install
yarn-install:
	-$(DC) run --rm --no-deps app bash -c "bin/yarn install"

# Run yarn upgrade
yarn-upgrade:
	-$(DC) run --rm --no-deps app bash -c "bin/yarn upgrade --silent --no-progress"

# Update deps and make a commit
LOCK_FILES=rails/Gemfile.lock rails/yarn.lock
deps-update: pull-ruby build-base bundle-update yarn-upgrade
	git add $(LOCK_FILES)
	git commit -m 'chore: Refresh base images and update dependencies' \
	  -m 'Commit created with `make deps-update`'

#----------------------------------------------------------

haml-lint:
	$(DCC) 'bundle exec haml-lint'

haml-lint-refresh-todos:
	$(DCC) 'bundle exec haml-lint --auto-gen-config'

haml-lint-with-todo:
	$(DCC) 'bundle exec haml-lint --config .haml-lint_todo.yml'

delint: haml-lint-with-todo

ansible-lint:
	@ansible-lint -p ansible/playbooks/deploy.yml -x yaml[indentation],no-handler

#----------------------------------------------------------

# View or edit encrypted secrets
# (Beware this is not the same as --environment=production)
#
secrets:
	-$(DC) run --rm --no-deps app bash -c "EDITOR=vi bin/rails credentials:edit"

dump-secrets:
	-@$(DC) run --rm --no-deps app bash -c "EDITOR=cat bin/rails credentials:edit" | head -n -1

devel-secrets:
	-$(DC) run --rm --no-deps app bash -c "EDITOR=vi bin/rails credentials:edit --environment=development"

devel-dump-secrets:
	-@$(DC) run --rm --no-deps app bash -c "EDITOR=cat bin/rails credentials:edit --environment=development" | head -n -1

#----------------------------------------------------------

# Run test suite
run-tests:
	$(DCC) 'bin/rails test:all'

test-ci:
	$(DC) run --rm app bash -c "bin/rails test:all"

coverage:
	$(DCC) 'env COVERAGE=1 bin/rails test:all'

onetest:
	$(DCC) 'bin/rails test $(TEST)'

test: run-tests
tests: run-tests

#----------------------------------------------------------

# (Use these if you want to run the prod container locally)
shell-prod: local-config prod-secrets prod-prerelease
	-$(DC_PROD) run --rm app bash

join-prod:
	-$(DC_PROD) exec app bash -c bash

start-prod: local-config prod-secrets prod-prerelease
	-$(DC_PROD) up

#----------------------------------------------------------

# Stop and remove containers, clean up unused images and remove
# the static files volume used by the prod container so to ensure
# it gets recreated fresh on startup
cleanup: tmp-clear
	$(DC) stop
	$(DC_PROD) stop
	$(DC) rm -f
	$(DC_PROD) rm -f
	$(D) image prune -f
	$(D) volume rm -f th_rails_static

#----------------------------------------------------------

# Get the email confirmation link when you sign up a new user locally.
# Grep them in the plain text part of the email.
#
signup-link:
	@$(DCC) 'grep "tiddlyhost.local/users/confirmation?confirmation_token=" log/development.log | grep -v "Started GET" | tail -1 | cut -d" " -f2'

# Get the reset password link after clicking "Forgot your password?" locally
#
forgot-link:
	@$(DCC) 'grep "tiddlyhost.local/users/password/edit?reset_password_token=" log/development.log | grep -v "Started GET" | tail -1 | cut -d" " -f2'

#----------------------------------------------------------

EMPTY_DIR=rails/tw_content/empties

EMPTY_URL_tw5=https://tiddlywiki.com/empty.html
EMPTY_URL_tw5x=https://tiddlywiki.com/empty-external-core.html
EMPTY_URL_feather=https://feather.wiki/builds/FeatherWiki_Warbler.html
EMPTY_URL_classic=https://classic.tiddlywiki.com/empty.html
EMPTY_URL_prerelease=https://tiddlywiki.com/prerelease/empty.html

CURL_FETCH=curl -sL $(EMPTY_URL_$1) -o $(EMPTY_DIR)/$1.html

download-empty-%: $(EMPTY_DIR)
	$(call CURL_FETCH,$*)

CORE_JS_URL=https://tiddlywiki.com/tiddlywikicore-$(VER).js

download-core-js:
	cd rails/public && curl -sL $(CORE_JS_URL) -O

download-empties: download-empty-tw5 download-empty-tw5x download-empty-feather download-empty-classic download-empty-prerelease download-core-js

PROD_PRERELEASE=docker/config/prerelease.html
$(PROD_PRERELEASE): $(EMPTY_DIR)/prerelease.html
	cp $< $@

prod-prerelease: $(PROD_PRERELEASE)

# Now that we have Feather Wiki included in ansible/fetch_empties
# this isn't used regularly, but keep it in case I ever want to
# build my own Feather Wiki empty for some reason.
#
FEATHER_BUILD=../FeatherWiki/builds/FeatherWiki_Warbler.html
FEATHER_EMPTY=$(EMPTY_DIR)/feather.html
$(FEATHER_EMPTY): $(FEATHER_BUILD)
	cp $? $@

feather-empty: $(FEATHER_EMPTY)

refresh-empties: empty-versions clear-empties download-empties

clear-empties:
	@rm -rf $(EMPTY_DIR)/*.html

empty-versions:
	@$(DCC) 'bin/rails runner "puts Empty.versions.to_yaml"' \
	  | grep -v 'Spring preloader' | grep -v '\-\-\-'

#----------------------------------------------------------

# Run this at build time since I don't want to check in the gzipped files
gzip-core-js-files:
	@for f in $$( ls rails/public/tiddlywikicore-*.js ); do \
	  gzip -c $$f > $$f.gz; \
	  echo Created $$f.gz; \
	done

#----------------------------------------------------------

EMPTIES_DIR=rails/tw_content/empties

require-var-%:
	@[[ ! -z "$$$(*)" ]] || ( echo "Environment var $(*) is required." && exit 1 )

ver-set: require-var-VER

# All the steps needed for a TiddlyWiki upgrade
# The version number must be provided manually like this:
#   VER=5.3.1 make tw5-update
#
tw5-update: ver-set $(TW5_DIR) download-empty-tw5 download-empty-tw5x download-core-js
	cp $(EMPTIES_DIR)/tw5.html $(EMPTIES_DIR)/tw5/$(VER).html
	cp $(EMPTIES_DIR)/tw5x.html $(EMPTIES_DIR)/tw5x/$(VER).html
	git add \
	  $(EMPTIES_DIR)/tw5.html \
	  $(EMPTIES_DIR)/tw5/$(VER).html \
	  $(EMPTIES_DIR)/tw5x.html \
	  $(EMPTIES_DIR)/tw5x/$(VER).html \
	  rails/public/tiddlywikicore-$(VER).js
	git commit -m 'chore: Upgrade TiddlyWiki empties to version $(VER)' \
	  -m 'Commit created with `VER=$(VER) make tw5-update`'

# Same thing for Feather Wiki
# You must specify the version manually here too:
#   VER=1.7.0 make feather-update
#
feather-update: ver-set download-empty-feather
	cp $(EMPTIES_DIR)/feather.html $(EMPTIES_DIR)/feather/Warbler_$(VER).html
	git add \
	  $(EMPTIES_DIR)/feather.html \
	  $(EMPTIES_DIR)/feather/Warbler_$(VER).html
	git commit -m 'chore: Upgrade Feather Wiki empties to version $(VER)' \
	  -m 'Commit created with `VER=$(VER) make feather-update`'

# Same thing for Classic
#   VER=2.10.1 make classic-update
classic-update: ver-set download-empty-classic
	cp $(EMPTIES_DIR)/classic.html $(EMPTIES_DIR)/classic/$(VER).html
	git add \
	  $(EMPTIES_DIR)/classic.html \
	  $(EMPTIES_DIR)/classic/$(VER).html
	git commit -m 'chore: Upgrade TiddlyWiki Classic empties to $(VER)' \
	  -m 'Commit created with `VER=$(VER) make classic-update`'

#----------------------------------------------------------

# Generate an SSL cert
# (If the cert exists, assume the key exists too.)
CERTS_DIR=docker/letsencrypt/live/tiddlyhost.local
cert: $(CERTS_DIR)/fullchain.pem

$(CERTS_DIR)/fullchain.pem:
	@bin/create-local-ssl-cert.sh $(CERTS_DIR)

clear-cert:
	@rm -f $(CERTS_DIR)/privkey.pem
	@rm -f $(CERTS_DIR)/fullchain.pem

redo-cert: clear-cert cert

#----------------------------------------------------------

no-uncommitted-diffs:
	@if ! git diff-index --quiet HEAD --; then \
	  echo "Aborting due to uncommitted diffs!"; \
	  git diff --numstat; \
	  exit 1; \
	fi

no-uncommitted-rails-files:
	@if [[ -n "$$( git status rails --porcelain )" ]]; then \
	  echo "Aborting due to uncommitted files under rails directory!"; \
	  git status rails --porcelain; \
	  exit 1; \
	fi

# Avoid accidentally deploying junk
build-ready: no-uncommitted-diffs no-uncommitted-rails-files

build-info:
	@bin/create-build-info.sh | tee rails/public/build-info.txt

build-prod: build-ready build-info js-math download-empty-prerelease gzip-core-js-files
	$(DC_PROD) build --progress plain app

build-prod-ci:
	$(DC_PROD) build app

fast-build-prod: build-info
	$(DC_PROD) build --progress plain app

push-base:
	$(D) --config etc/docker-conf push sbaird/tiddlyhost-base

push-prod:
	$(D) --config etc/docker-conf push sbaird/tiddlyhost

# Fixme: There are too many options here...
build-push:            delint tests build-prod push-prod
build-full-deploy:     build-push full-deploy
build-deploy:          build-push deploy-app
fast-build-deploy:     fast-build-prod push-prod fast-deploy-app

PLAY=ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook -i ansible/inventory.yml $(V)

DEPLOY=$(PLAY) ansible/playbooks/deploy.yml --limit prod
RESTART=$(PLAY) ansible/playbooks/restart.yml --limit prod
BACKUP=$(PLAY) ansible/playbooks/backup.yml --limit prod

LOCAL_DEPLOY=$(PLAY) ansible/playbooks/deploy.yml --limit localhost --ask-become-pass --connection local

full-deploy:
	$(DEPLOY)

deploy-deps:
	$(DEPLOY) --tags=deps

deploy-certs:
	$(DEPLOY) --tags=certs

deploy-scripts:
	$(DEPLOY) --tags=scripts

refresh-prerelease:
	$(DEPLOY) --tags=refresh-prerelease

deploy-app:
	$(DEPLOY) --tags=app

fast-deploy-app:
	$(DEPLOY) --tags=fast-upgrade

deploy-app-bootstrap:
	$(DEPLOY) --tags=app,db-create

deploy-cleanup:
	$(DEPLOY) --tags=cleanup

deploy-secrets:
	$(DEPLOY) --tags=secrets

# If you want to run selected tasks givem them the foo tag
deploy-foo:
	$(DEPLOY) --tags=foo --diff

# To change some docker configuration locally since dnf update seems to reverts it
local-docker-fix:
	$(LOCAL_DEPLOY) --tags=local-docker-fix

restart-jobs:
	$(RESTART) -e restart_list=jobs

restart-app:
	$(RESTART) -e restart_list=app

#----------------------------------------------------------

TIMESTAMP := $(shell date +%Y%m%d%H%M%S)

TOP_DIR=$(shell git rev-parse --show-toplevel)
BACKUPS_DIR=$(TOP_DIR)/../thost-backups
S3_BACKUPS=$(BACKUPS_DIR)/s3
DB_BACKUPS=$(BACKUPS_DIR)/db

db-backup:
	mkdir -p $(DB_BACKUPS)/$(TIMESTAMP)
	$(BACKUP) -e local_backup_subdir=$(TIMESTAMP) -e local_backup_dir=$(DB_BACKUPS) --limit=prod
	ls -l $(DB_BACKUPS)/$(TIMESTAMP)
	zcat $(DB_BACKUPS)/$(TIMESTAMP)/dbdump.gz | grep '^-- ' | head -3
	du -h -s $(DB_BACKUPS)/$(TIMESTAMP)
	du -h -s $(DB_BACKUPS)

s3-bucket-name: require-var-BUCKET_NAME

# Assume you have suitable s3 credentials available

# Copy down new versions of sites, keeping old versions locally
s3-backup: s3-bucket-name
	aws s3 sync s3://$(BUCKET_NAME) $(S3_BACKUPS)/latest
	du -h $(S3_BACKUPS)

# Copy down new versions of sites, removing old versions locally
s3-backup-and-prune: s3-bucket-name
	aws s3 sync s3://$(BUCKET_NAME) $(S3_BACKUPS)/latest --delete
	du -h $(S3_BACKUPS)

# Ineffiently copy down everything to a timestamp directory
# Deprecated. Use s3-snapshot-and-prune instead.
s3-full-snapshot: s3-bucket-name
	aws s3 sync s3://$(BUCKET_NAME) $(S3_BACKUPS)/$(TIMESTAMP)
	du -h $(S3_BACKUPS)

s3-local-timestamped-copy:
	cp -r $(S3_BACKUPS)/latest $(S3_BACKUPS)/latest-$(TIMESTAMP)

# Keep some deleted sites, but try not to keep multiples of them
s3-snapshot-and-prune: s3-backup s3-local-timestamped-copy s3-backup-and-prune

show-backups:
	@du -h $(BACKUPS_DIR)

show-latest-db-backup:
	@NEWEST=$$( ls -t $(DB_BACKUPS) | head -1 ) && \
	  ls -l $(DB_BACKUPS)/$$NEWEST && \
	  zcat $(DB_BACKUPS)/$$NEWEST/dbdump | wc -l && \
	  zcat $(DB_BACKUPS)/$$NEWEST/dbdump | head && \
	  echo . && echo . && echo . && \
	  zcat $(DB_BACKUPS)/$$NEWEST/dbdump | tail -4

# Example usage:
#   make s3-extract FILEKEY=bc1viib59bbw3cpqvvd2x7dnth9b
s3-extract:
	openssl zlib -d -in $(S3_BACKUPS)/latest/$(FILEKEY) > $(FILEKEY).html

full-backup: db-backup s3-backup
full-backup-and-snapshot: db-backup s3-snapshot-and-prune

#----------------------------------------------------------

# For credentials: source etc/openrc.sh
openstack-info:
	openstack server show thost

# If you can't ping then...
openstack-reboot:
	openstack server reboot thost

openstack-reboot-hard:
	openstack server reboot --hard thost

#----------------------------------------------------------

PROD_INFO_URL=https://tiddlyhost.com/build-info.txt

prod-info:
	@-curl -s $(PROD_INFO_URL)

prod-diff:
	@-( \
	  echo '## Prod build info' && \
	  $(MAKE) prod-info && \
	  echo '' && \
	  echo '## Prod diff' && \
	  git diff --color=always $$(curl -s $(PROD_INFO_URL) | grep 'sha:' | cut -d: -f2) \
	) | less -REXS

#----------------------------------------------------------
JS_MATH_ZIP=jsMath-3.3g.zip
JS_MATH_FONTS_ZIP=jsMath-fonts-1.3.zip

JS_MATH_DOWNLOADS=https://sourceforge.net/projects/jsmath/files

$(JS_MATH_ZIP):
	curl -sL $(JS_MATH_DOWNLOADS)/jsMath/3.3g/$(JS_MATH_ZIP)/download -o $(JS_MATH_ZIP)

$(JS_MATH_FONTS_ZIP):
	curl -sL $(JS_MATH_DOWNLOADS)/jsMath%20Image%20Fonts/1.3/$(JS_MATH_FONTS_ZIP)/download -o $(JS_MATH_FONTS_ZIP)

rails/public/jsMath/jsMath.js: $(JS_MATH_ZIP) $(JS_MATH_FONTS_ZIP)
	cd rails/public && unzip -q ../../$(JS_MATH_ZIP)
	cd rails/public/jsMath && unzip -q ../../../$(JS_MATH_FONTS_ZIP)
	@touch rails/public/jsMath/jsMath.js # so make doesn't think it's stale

js-math: rails/public/jsMath/jsMath.js

js-math-clean:
	rm -rf rails/public/jsMath

js-math-purge: js-math-clean
	rm -f $(JS_MATH_ZIP) $(JS_MATH_FONTS_ZIP)

#----------------------------------------------------------

stripe-dev-listen:
	stripe listen --forward-to https://tiddlyhost.local/pay/webhooks/stripe --skip-verify

#----------------------------------------------------------

/tmp/Simon\ Baird.png:
	@curl -s -o '$@' \
	  https://www.gravatar.com/avatar/bfaba91f41f0c01aba1ef0751458b537

gource-image: /tmp/Simon\ Baird.png

pretty-colors: gource-image
	@SDL_VIDEODRIVER=x11 gource \
	  --user-image-dir /tmp \
	  --seconds-per-day 0.07 \
	  --key \
	  --title 'Tiddlyhost Development' \
	  --fullscreen \
	  --frameless \
	  --auto-skip-seconds 0.3 \
	  --elasticity 0.1 \
	  --font-scale 5 \
	  --font-size 6 \
	  --dir-font-size 5 \
	  --user-font-size 5 \
	  --file-font-size 5 \
	  --bloom-multiplier 0.2 \
	  --bloom-intensity 0.2 \
	  --filename-colour 555555 \
	  --dir-colour 555555 \
	  ;
