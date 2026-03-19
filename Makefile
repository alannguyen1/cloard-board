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
	zsh tests/test_liveness.sh
	zsh tests/test_list_mode.sh
	zsh tests/test_list_render.sh
	zsh tests/test_session_history.sh
	zsh tests/test_unified_modal.sh
	zsh tests/test_status_changed_at.sh
	zsh tests/test_time_ago.sh
	zsh tests/test_gc.sh

clean:
	@echo "cloard-board is the built artifact; not cleaning"
