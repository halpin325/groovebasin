fs = require 'fs'
http = require 'http'
net = require 'net'
socketio = require 'socket.io'
node_static = require 'node-static'
mpd = require './mpd'
extend = require 'node.extend'
{spawn} = require 'child_process'

arrayToObject = (array) ->
  obj = {}
  obj[item] = true for item in array
  obj

exec = (cmd, args=[], cb=->) ->
  bin = spawn(cmd, args)
  bin.stdout.on 'data', (data) ->
    process.stdout.write data
  bin.stderr.on 'data', (data) ->
    process.stderr.write data
  bin.on 'exit', cb

is_dev_mode = process.env.npm_package_config_development_mode is 'true'
makeAssetsIfDev = (cb) ->
  if is_dev_mode
    exec "cake", ["build"], cb
  else
    cb()

fileServer = new (node_static.Server) "./public"
app = http.createServer((request, response) ->
  makeAssetsIfDev ->
    unless plugins.handleRequest(request, response)
      fileServer.serve request, response
).listen(process.env.npm_package_config_port)
io = socketio.listen(app)
io.set 'log level', process.env.npm_package_config_log_level
log = io.log
log.info "Serving at http://localhost:#{process.env.npm_package_config_port}/"

# downgrade user permissions
try
  process.setuid uid if uid = process.env.npm_package_config_user_id
catch error
  log.error "error setting uid: #{error}"
log.info "server running as user #{process.getuid()}"


plugins =
  objects:
    lastfm: null
    dynamicmode: null
    upload: null
    download: null
    chat: null
    stream: null
  initialize: ->
    for name of this.objects
      plugin = this.objects[name] = new (require("./plugins/#{name}").Plugin)()
      plugin.log = log
      plugin.onStateChanged = saveState
      plugin.onStatusChanged = ->
        saveState()
        sendStatus()
  call: (fn_name, args...) ->
    plugin[fn_name](args...) for name, plugin of this.objects
  handleRequest: (request, response) ->
    for name, plugin of this.objects
      return true if plugin.handleRequest(request, response)
    return false
  featuresList: ->
    ([name, plugin.is_enabled] for name, plugin of this.objects)

# state management
state =
  state_version: 2 # bump this whenever persistent state should be discarded
  status: {} # this structure is visible to clients

saveState = ->
  plugins.call "saveState", state
  fs.writeFile process.env.npm_package_config_state_file, JSON.stringify(state, null, 4), "utf8"

restoreState = ->
  try loaded_state = JSON.parse fs.readFileSync process.env.npm_package_config_state_file, "utf8"
  if loaded_state?.state_version is state.state_version
    extend true, state, loaded_state
  # have the plugins restore and then save to delete values that should not
  # have been restored.
  plugins.call "restoreState", state
  plugins.call "saveState", state

sendStatus = ->
  plugins.call "onSendStatus", state.status
  io.sockets.emit 'Status', JSON.stringify state.status

plugins.initialize()
restoreState()

# read mpd conf
mpd_conf = null
root_pass = null
do ->
  mpd_conf_path = process.env.npm_package_config_mpd_conf
  try
    data = fs.readFileSync(mpd_conf_path)
  catch error
    log.warn "Unable to read #{mpd_conf_path}: #{error}. Most features disabled."
    return
  mpd_conf = require('./mpdconf').parse(data.toString())

  plugins.call "setConf", mpd_conf, mpd_conf_path

  if mpd_conf.auto_update isnt "yes"
    log.warn "recommended to turn auto_update on in #{mpd_conf_path}"
  if mpd_conf.gapless_mp3_playback isnt "yes"
    log.warn "recommended to turn gapless_mp3_playback on in #{mpd_conf_path}"
  if mpd_conf.volume_normalization isnt "yes"
    log.warn "recommended to turn volume_normalization on in #{mpd_conf_path}"
  if isNaN(n = parseInt(mpd_conf.max_command_list_size)) or n < 16384
    log.warn "recommended to set max_command_list_size to >= 16384 in #{mpd_conf_path}"


  all_permissions = "read,add,control,admin"
  accountIsRoot = (account) ->
    for perm in all_permissions.split(',')
      if not account[perm]
        return false
    return true

  default_account = arrayToObject((mpd_conf.default_permissions ? all_permissions).split(","))
  if accountIsRoot(default_account)
    root_pass = ""
  accounts = {}
  for account_str in (mpd_conf.password ? [])
    [password, perms] = account_str.split("@")
    accounts[password] = account = arrayToObject(perms.split(","))
    if not root_pass? and accountIsRoot(account)
      root_pass = password

  if default_account.admin
    log.warn "Anonymous users have admin permissions. Recommended to remove `admin` from `default_permissions` in #{mpd_conf_path}"
  if not root_pass?
    rand_pass = Math.floor(Math.random() * 99999999999)
    log.error """
      It is required to have at least one password which is granted all the
      permissions. Recommended to add this line in #{mpd_conf_path}:

        password "groovebasin-#{rand_pass}@#{all_permissions}"

      """
    process.exit(1)

plugins.call "saveState", state

for [name, enabled] in plugins.featuresList()
  if enabled
    log.info "#{name} is enabled."
  else
    log.warn "#{name} is disabled."

createMpdConnection = (unix_socket, cb) ->
  if unix_socket and (path = mpd_conf?.bind_to_address?.unix_socket)?
    net.connect path, cb
  else
    port = mpd_conf?.port ? 6600
    host = mpd_conf?.bind_to_address?.network ? "localhost"
    net.connect port, host, cb

connectBrowserMpd = (socket) ->
  mpd_socket = createMpdConnection false, ->
    log.debug "browser to mpd connect"
    try socket.emit 'MpdConnect'
  mpd_socket.on 'data', (data) ->
    socket.emit 'FromMpd', data.toString()
  mpd_socket.on 'end', ->
    log.debug "browser mpd disconnect"
    try socket.emit 'MpdDisconnect'
  mpd_socket.on 'error', ->
    log.debug "browser no mpd daemon found."

  socket.removeAllListeners 'ToMpd'
  socket.on 'ToMpd', (data) ->
    log.debug "[in] #{data}"
    try mpd_socket.write data
  socket.removeAllListeners 'disconnect'
  socket.on 'disconnect', ->
    mpd_socket.end()

io.sockets.on 'connection', (socket) ->
  connectBrowserMpd socket
  plugins.call "onSocketConnection", socket

# our own mpd connection
class DirectMpd extends mpd.Mpd
  constructor: (@mpd_socket) ->
    super()
    @mpd_socket.on 'data', @receive

  rawSend: (data) =>
    try @mpd_socket.write data


my_mpd = null
my_mpd_socket = null
connect_success = true
connectServerMpd = ->
  my_mpd_socket = createMpdConnection true, ->
    log.info "server to mpd connect"
    connect_success = true
    my_mpd.handleConnectionStart()
    if root_pass.length > 0
      my_mpd.authenticate root_pass

    # connect socket clients to mpd
    io.sockets.clients().forEach connectBrowserMpd
  my_mpd_socket.on 'end', ->
    log.warn "server mpd disconnect"
    tryReconnect()
  my_mpd_socket.on 'error', ->
    if connect_success
      connect_success = false
      log.warn "server no mpd daemon found."
    tryReconnect()
  my_mpd = new DirectMpd(my_mpd_socket)
  my_mpd.on 'error', (msg) -> log.error msg

  plugins.call "setMpd", my_mpd

tryReconnect = ->
  setTimeout connectServerMpd, 1000

connectServerMpd()
