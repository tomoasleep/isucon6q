worker_processes 5
preload_app true
timeout 120

if ENV['RACK_ENV'] == 'production'
  stderr_path File.expand_path('../../../log/isuda_unicorn_stderr.log', __FILE__)
  stdout_path File.expand_path('../../../log/isuda_unicorn_stdout.log', __FILE__)
  listen "/tmp/isuda-unicorn.sock"
end
