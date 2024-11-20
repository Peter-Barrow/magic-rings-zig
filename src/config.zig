const std = @import("std");
const knownFolders = @import("known-folders");

// Configuration for shared memory object
// Holds information about the opened magic-ring
//      - path to shared memory
//      - number of connections?
//      - library version
//      - size of shared memory
//      - size of elemnts
//      - type of elements (maybe just name?)
// Must have defineable target directory
