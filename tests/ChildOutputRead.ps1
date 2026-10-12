# Reads a child process's redirected standard output or standard error on a thread of its own (U92).
#
# On Windows, .NET 10 redirects a child's streams through synchronous anonymous pipes, so ReadToEndAsync holds a
# thread-pool thread for each pipe until the child closes it, and a read queued behind busy threads can start long
# after the child exited (Process.Windows.cs, dotnet/runtime#81896). A LongRunning task runs on a dedicated thread
# outside the pool: ThreadPoolTaskScheduler.QueueTask, "Run LongRunning tasks on their own dedicated thread"
# (dotnet/runtime release/10.0). tests/Test-ChildOutputRead.ps1 checks both functions with every pool worker busy.

function Start-ChildOutputRead {
    param([Parameter(Mandatory)][IO.StreamReader]$Reader)
    [Threading.Tasks.Task[string]]::Factory.StartNew([Func[string]]$Reader.ReadToEnd, [Threading.CancellationToken]::None,
        [Threading.Tasks.TaskCreationOptions]::LongRunning, [Threading.Tasks.TaskScheduler]::Default)
}

# The whole text of a read. A read still open TimeoutSeconds after its process exited is held by a process that the
# child started and that inherited the pipe: its text is not complete, so this throws instead of returning it.
function Receive-ChildOutputRead {
    param([Parameter(Mandatory)][Threading.Tasks.Task[string]]$Read, [Parameter(Mandatory)][string]$Name, [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60)
    if (-not $Read.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        throw "$Name was still open $TimeoutSeconds s after its process exited: a process it started holds the pipe, so its output is not complete."
    }
    $Read.Result
}
