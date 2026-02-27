.PHONY: build test clean

build:
	./build.sh

test: build
	zsh tests/test_fixes.sh
	zsh tests/test_cron.sh
	zsh tests/test_reopen.sh
	zsh tests/test_viewport.sh
	zsh tests/test_session.sh
	zsh tests/test_modal.sh

clean:
	@echo "cloard-board is the built artifact; not cleaning"
