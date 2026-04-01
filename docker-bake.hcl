variable "ARCH" {
  default = "arm64"
}

variable "PLATFORM" {
  default = "linux/arm64"
}

variable "CACHE_DIR" {
  default = ".buildcache"
}

target "_defaults" {
  dockerfile = "Dockerfile"
  cache-from = [
    "type=local,src=${CACHE_DIR}/tdarr",
    "type=local,src=${CACHE_DIR}/tdarr_node",
  ]
}

target "av1-stack" {
  inherits  = ["_defaults"]
  target    = "av1-stack"
  platforms = [PLATFORM]
  tags      = ["av1-stack:${ARCH}"]
  output    = ["type=cacheonly"]
}

target "av1-stack-load" {
  inherits = ["av1-stack"]
  output   = ["type=docker"]
}

target "tdarr" {
  inherits  = ["_defaults"]
  target    = "tdarr"
  platforms = [PLATFORM]
  tags      = ["tdarr:${ARCH}"]
  output    = ["type=docker"]
  contexts  = { av1-stack = "target:av1-stack" }
  cache-to  = ["type=local,dest=${CACHE_DIR}/tdarr,mode=max"]
}

target "tdarr_node" {
  inherits  = ["_defaults"]
  target    = "tdarr_node"
  platforms = [PLATFORM]
  tags      = ["tdarr_node:${ARCH}"]
  output    = ["type=docker"]
  contexts  = { av1-stack = "target:av1-stack" }
  cache-to  = ["type=local,dest=${CACHE_DIR}/tdarr_node,mode=max"]
}

group "stack-only" {
  targets = ["av1-stack-load"]
}
