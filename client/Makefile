# Makefile to generate the extension out of separate sql source files.
# Once a version is released, it is not meant to be changed. E.g: once version 0.0.1 is out, it SHALL NOT be changed.
EXTENSION = cdb_dataservices_client
EXTVERSION = $(shell grep default_version $(EXTENSION).control | sed -e "s/default_version[[:space:]]*=[[:space:]]*'\([^']*\)'/\1/")

# The new version to be generated from templates
SED = sed
ERB = erb
REPLACEMENTS = -i 's/$(EXTVERSION)/$(NEW_VERSION)/g'
NEW_EXTENSION_ARTIFACT = $(EXTENSION)--$(EXTVERSION).sql

# OLD_VERSIONS = $(wildcard old_versions/*.sql)
# DATA =  $(NEW_EXTENSION_ARTIFACT) \
#   $(OLD_VERSIONS) \
#   cdb_dataservices_client--0.11.0--0.11.1.sql \
#   cdb_dataservices_client--0.11.1--0.11.0.sql
OLD_VERSIONS = $(wildcard old_versions/*.sql)
DATA = $(NEW_EXTENSION_ARTIFACT) \
		 $(EXTENSION)--*--*.sql \
		 $(OLD_VERSIONS)
SOURCES_DATA_DIR = sql/


REGRESS = $(notdir $(basename $(wildcard test/sql/*test.sql)))
TEST_DIR = test/
REGRESS_OPTS = --inputdir='$(TEST_DIR)' --outputdir='$(TEST_DIR)' --user='postgres'

# DATA is a special variable used by postgres build infrastructure
# These are the files to be installed in the server shared dir,
# for installation from scratch, upgrades and downgrades.
# @see http://www.postgresql.org/docs/current/static/extend-pgxs.html

# The interface definition is used along with some templates to automatically generate code
RENDERER = renderer/sql-template-renderer
INTERFACE_FILE = renderer/interface.yaml
TEMPLATE_DIR = renderer/templates
TEMPLATE_FILES = $(wildcard $(TEMPLATE_DIR)/*.erb)
GENERATED_SQL_FILES = $(patsubst $(TEMPLATE_DIR)/%.erb, $(SOURCES_DATA_DIR)/%.sql, $(TEMPLATE_FILES))

# postgres build stuff
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

$(GENERATED_SQL_FILES): $(SOURCES_DATA_DIR)/%.sql: $(TEMPLATE_DIR)/%.erb $(INTERFACE_FILE) $(RENDERER)
	$(RENDERER) $(INTERFACE_FILE) $< > $@

SOURCES_DATA = $(wildcard $(SOURCES_DATA_DIR)/*.sql) $(GENERATED_SQL_FILES)

$(NEW_EXTENSION_ARTIFACT): $(SOURCES_DATA)
	rm -f $@
	cat $(SOURCES_DATA_DIR)/*.sql >> $@

.PHONY: all
all: $(DATA)

.PHONY: release
release: $(EXTENSION).control $(SOURCES_DATA)
	test -n "$(NEW_VERSION)"  # $$NEW_VERSION VARIABLE MISSING. Eg. make release NEW_VERSION=0.x.0
	git mv *.sql old_versions
	$(SED) $(REPLACEMENTS) $(EXTENSION).control
	git add $(EXTENSION).control
	cat $(SOURCES_DATA_DIR)/*.sql > $(EXTENSION)--$(NEW_VERSION).sql
	git add $(EXTENSION)--$(NEW_VERSION).sql
	$(ERB) version=$(NEW_VERSION) upgrade_downgrade_template.erb > $(EXTENSION)--$(EXTVERSION)--$(NEW_VERSION).sql
	$(ERB) version=$(EXTVERSION) upgrade_downgrade_template.erb > $(EXTENSION)--$(NEW_VERSION)--$(EXTVERSION).sql

# Only meant for development time, do not use once a version is released
.PHONY: devclean
devclean:
	rm -f $(NEW_EXTENSION_ARTIFACT)
	rm -f $(GENERATED_SQL_FILES)
