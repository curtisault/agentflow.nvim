# AgentFlow — dev tasks

.PHONY: test lint check clean

# Run the full test suite via plenary.nvim (run each file sequentially)
TEST_FILES := $(wildcard tests/test_*.lua)

test: $(TEST_FILES)
	@exit_code=0; \
	for f in $(TEST_FILES); do \
	  nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile $$f" -c "qa!" 2>&1 || exit_code=1; \
	done; \
	exit $$exit_code

# Run a single test file
test-file:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile $(FILE)" -c "qa!"

# Lint with luacheck (brew install luacheck)
lint:
	luacheck lua/agentflow/ --globals vim --no-max-line-length

# Run :checkhealth inside Neovim
check:
	nvim --headless -c "checkhealth agentflow" -c "qa!"

# Remove generated session data
clean:
	rm -rf .agentflow/
