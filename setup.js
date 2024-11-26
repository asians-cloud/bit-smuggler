var sh = require('shelljs')
var http = require('http')
var fs = require('fs')
var os = require('os')
var path = require('path')

if (__dirname !== sh.pwd().stdout) {
  console.error("need to run the script from its directory")
  process.exit(1)
}

function getNixDistro() {
  var distroProps = {}
  sh.cat("/etc/*-release").split("\n")
               .forEach(function(s) {
                    var ss = s.split('=')
                    distroProps[ss[0]] = ss[1]
                })
  return { distro: distroProps
         , arch: {"x86_64": "x64", "i386": "i386"}[sh.exec("uname -m").stdout.trim()]}
}

function makeNixVersion(os) {
  return "linux-" + os.arch + "-" + os.distro.DISTRIB_ID.toLowerCase()
         + "-" + os.distro.DISTRIB_RELEASE.replace(new RegExp("\\.", 'g'), "-")
}

// download the client linux utorrent 
function downloadUTServer(target) {
  var file = fs.createWriteStream(target)
  // var url = "http://download-new.utorrent.com/os/" + makeNixVersion(getNixDistro()) + "/track/beta/endpoint/utserver/"
  var url = "http://download.utorrent.com/linux/utorrent-server-3.0-25053.tar.gz"
  // var request = http.get(url, function(response) {response.pipe(file)})
  sh.exec("wget " + url + " -O " + target)
}

var nixDistro = getNixDistro()
console.log(makeNixVersion(nixDistro))

// store the binaries in the right places
function setupUTorrentBinary() {
  var binPath = "./utserver" 
  var archive = "utserver.tar.gz"
  var unarchivedDir = path.join(binPath, "unarchived")
  sh.rm('-rf', binPath) // clean up first
  sh.mkdir("-p", unarchivedDir)
  var archivePath = path.join(binPath, archive)
  console.log("downloading utserver for your os distro...")
  downloadUTServer(archivePath)
  console.log("download finished.")
  sh.exec("tar -xvf " + archivePath + " -C " + unarchivedDir)
  return  path.join(unarchivedDir, sh.ls(unarchivedDir)[0])
}


// for both server and client
function createPeerDir(root, utDir) {
  console.log("setting up peer dirs in " + root)
  var cachePath = path.join(root, "cache")
  var clientPath = path.join(root, "utorrent-client")
  sh.mkdir("-p", cachePath, clientPath)
  sh.cp("-r", path.join(utDir, "*"), clientPath) //copy just the contents
}

function createTestSetup(utServerBinDir) {
  var testPath = "BitSmuggler/test-data/integration-test"
  var clientPath = path.join(testPath, "client")
  var serverPath = path.join(testPath, "server")
  sh.mkdir("-p", clientPath, serverPath)

  createPeerDir(clientPath, utServerBinDir)
  createPeerDir(serverPath, utServerBinDir)

}

function addNonHackageDeps() {
  var deps = ["https://github.com/asians-cloud/tcp-proxy"
  , "https://github.com/asians-cloud/shepherd"
  , "https://github.com/asians-cloud/helligator"
  , "https://github.com/asians-cloud/free-network-protocol"
  , "https://github.com/asians-cloud/bittorrent-client-control"]
  for (i in deps) {
    sh.exec("git clone " + deps[i])
  }
  process.chdir("BitSmuggler")

  console.log("creating a cabal sandbox...")
  sh.exec("cabal sandbox init")

  console.log("adding source for each sandbox...")
  for (i in deps) {
    sh.exec("cabal sandbox add-source ../" + path.basename(deps[i]))
  }
  process.chdir("..") // go back
}

// MAIN 
var utBin = setupUTorrentBinary()
createTestSetup(utBin)
addNonHackageDeps()
