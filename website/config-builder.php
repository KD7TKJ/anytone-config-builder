<?php
/**
 * Stateless JSON endpoint for the JavaScript-enhanced frontend.
 *
 * Accepts a JSON POST body and pipes it to anytone-config-builder.pl
 * running in --json-mode. Returns the Perl script's stdout as the
 * HTTP response.
 *
 * No files are written to disk. The Perl script is expected to emit
 * valid JSON on stdout for both success and error cases.
 *
 * Response discipline:
 *   - The entire response body is buffered.
 *   - A shutdown handler emits it, so PHP fatals still produce JSON.
 *   - Content-Type is set only when we're about to emit.
 *   - display_errors is off; everything goes to the error log.
 *
 * Security:
 *   - proc_open is called with an array argv, bypassing the shell.
 *   - Request bodies larger than 5 MB are rejected before parsing.
 *   - The Perl script and config directory are resolved with absolute
 *     paths derived from __DIR__, so the endpoint is independent of
 *     its own working directory.
 */

error_reporting(E_ALL);
ini_set('display_errors', 0);
ini_set('log_errors', 1);

// Swallow any output that PHP or our own code might accidentally produce.
ob_start();

$response_body = null;
$response_status = 200;

function emit_json($data, $status = 200)
{
    global $response_body, $response_status;
    $response_body = json_encode($data);
    $response_status = $status;
}

function finalize_response()
{
    global $response_body, $response_status;

    // Discard anything buffered (warnings, notices, stray output).
    while (ob_get_level() > 0) {
        ob_end_clean();
    }

    if ($response_body === null) {
        $response_body = json_encode([
            'status'  => 'error',
            'message' => 'Server error: no response was produced',
        ]);
        $response_status = 500;
    }

    if (!headers_sent()) {
        header('Content-Type: application/json');
        http_response_code($response_status);
    }
    echo $response_body;
}

register_shutdown_function('finalize_response');

// -----------------------------------------------------------------
// Request parsing
// -----------------------------------------------------------------

$raw = file_get_contents('php://input');
if ($raw === false || strlen($raw) === 0) {
    emit_json(['status' => 'error', 'message' => 'Empty request body'], 400);
    return;
}

if (strlen($raw) > 5 * 1024 * 1024) {
    emit_json(['status' => 'error', 'message' => 'Request too large'], 413);
    return;
}

$request = json_decode($raw, true);
if (!is_array($request)) {
    emit_json(['status' => 'error', 'message' => 'Invalid JSON in request'], 400);
    return;
}

// -----------------------------------------------------------------
// Locate the Perl script and config directory.
//
// This file lives in website/. The Perl script and its config sit
// one directory up, at the repository root. __DIR__ gives us the
// absolute path of this file's directory regardless of CWD.
// -----------------------------------------------------------------

$project_root = dirname(__DIR__);
$script_path  = $project_root . '/anytone-config-builder.pl';
$config_dir   = $project_root . '/config';

if (!is_file($script_path)) {
    emit_json(['status' => 'error', 'message' => 'Perl script not found'], 500);
    return;
}

// -----------------------------------------------------------------
// Spawn the Perl script.
//
// Passing an array to proc_open bypasses the shell entirely: no
// escapeshellarg, no metacharacter interpretation, no /bin/sh in the
// process tree.
// -----------------------------------------------------------------

$cmd = [
    $script_path,
    '--json-mode',
    '--config=' . $config_dir,
];

$descriptors = [
    0 => ['pipe', 'r'],
    1 => ['pipe', 'w'],
    2 => ['pipe', 'w'],
];

$process = proc_open($cmd, $descriptors, $pipes);
if (!is_resource($process)) {
    emit_json(['status' => 'error', 'message' => 'Could not start Perl script'], 500);
    return;
}

fwrite($pipes[0], $raw);
fclose($pipes[0]);

$stdout = stream_get_contents($pipes[1]);
$stderr = stream_get_contents($pipes[2]);
fclose($pipes[1]);
fclose($pipes[2]);
$exit_code = proc_close($process);

if ($stderr !== '') {
    error_log('anytone-config-builder stderr: ' . $stderr);
}

if (strlen($stdout) === 0) {
    emit_json([
        'status'  => 'error',
        'message' => 'Perl script produced no output',
        'exit'    => $exit_code,
    ], 500);
    return;
}

// Pass the Perl output through verbatim. The Perl script is contractually
// obligated to emit valid JSON; if it doesn't, the client will see the
// parse failure and we'll have the stderr in the log.
$decoded = json_decode($stdout, true);
if ($decoded === null) {
    error_log('anytone-config-builder produced non-JSON stdout: ' . substr($stdout, 0, 500));
    emit_json([
        'status'  => 'error',
        'message' => 'Perl script produced invalid JSON',
    ], 500);
    return;
}

echo $stdout;
$response_body = $stdout;   // tell finalize_response not to overwrite
$response_status = 200;