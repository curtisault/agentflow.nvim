-- util/subprocess.lua — vim.fn.jobstart wrapper with a coroutine-friendly interface.
--
-- Usage (inside a coroutine / async context):
--   local result, err = subprocess.run({
--     cmd     = { "claude", "api", "messages" },
--     stdin   = json_payload,
--     timeout = 30000,
--     on_stdout = function(line) ... end,  -- optional streaming callback
--   })

local M = {}

local log = require("agentflow.util.log")

--- Run a subprocess and collect its output.
---
--- Must be called from within a coroutine (e.g. via util/async.lua).
--- Yields until the process exits or times out.
---
--- @param opts table {
---   cmd       string[]         Command and arguments
---   stdin     string|nil       Data to pipe to stdin (sent all at once then closed)
---   timeout   number|nil       Milliseconds before the job is killed (default: 30000)
---   on_stdout fun(line:string)|nil  Called for each stdout line as it arrives
---   on_stderr fun(line:string)|nil  Called for each stderr line as it arrives
--- }
--- @return table|nil result  { stdout: string, stderr: string, code: number }
--- @return string|nil error  Error message if something went wrong
function M.run(opts)
  local co = coroutine.running()
  assert(co, "subprocess.run() must be called from within a coroutine")

  opts = opts or {}
  local timeout_ms = opts.timeout or 30000

  local stdout_chunks = {}
  local stderr_chunks = {}
  local job_id
  local timer

  local function resume(result, err)
    if timer then
      timer:stop()
      if not timer:is_closing() then timer:close() end
      timer = nil
    end
    coroutine.resume(co, result, err)
  end

  local job_opts = {
    stdout_buffered = false,
    stderr_buffered = false,

    on_stdout = function(_, data, _)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stdout_chunks, line)
          if opts.on_stdout then
            pcall(opts.on_stdout, line)
          end
        end
      end
    end,

    on_stderr = function(_, data, _)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_chunks, line)
          if opts.on_stderr then
            pcall(opts.on_stderr, line)
          end
        end
      end
    end,

    on_exit = function(_, code, _)
      log.debug("subprocess exited", { code = code, cmd = opts.cmd[1] })
      resume({
        stdout = table.concat(stdout_chunks, "\n"),
        stderr = table.concat(stderr_chunks, "\n"),
        code   = code,
      }, nil)
    end,
  }

  -- Pipe stdin only if data was provided
  if opts.stdin then
    job_opts.stdin = "pipe"
  end

  job_id = vim.fn.jobstart(opts.cmd, job_opts)

  if job_id <= 0 then
    local msg = job_id == 0
      and "subprocess.run: invalid arguments to jobstart"
      or  "subprocess.run: command not found: " .. (opts.cmd[1] or "?")
    log.error(msg)
    return nil, msg
  end

  log.debug("subprocess started", { job_id = job_id, cmd = opts.cmd[1] })

  -- Send stdin and close the pipe
  if opts.stdin then
    vim.fn.chansend(job_id, opts.stdin)
    vim.fn.chanclose(job_id, "stdin")
  end

  -- Set up timeout via libuv timer
  timer = vim.loop.new_timer()
  timer:start(timeout_ms, 0, vim.schedule_wrap(function()
    log.warn("subprocess timed out, killing job", { job_id = job_id, timeout_ms = timeout_ms })
    vim.fn.jobstop(job_id)
    resume(nil, "subprocess timed out after " .. timeout_ms .. "ms")
  end))

  -- Yield; will be resumed by on_exit or the timeout timer
  return coroutine.yield()
end

--- Send a signal to a running job (e.g. to cancel it).
--- @param job_id number
function M.kill(job_id)
  if job_id and job_id > 0 then
    vim.fn.jobstop(job_id)
  end
end

return M
