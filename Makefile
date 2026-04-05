# AgentFlow — dev tasks

.PHONY: test lint check clean

# Run the full test suite via plenary.nvim
test:
	nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {sequential=true}" -c "qa!"

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
