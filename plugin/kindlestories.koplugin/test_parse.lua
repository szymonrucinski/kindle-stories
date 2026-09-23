package.path = "./?.lua;" .. package.path
local p = require("parse")
local s, t = p.parse("Once upon a time")
assert(s == "Once upon a time" and t == nil)
s, t = p.parse("The end.achieved tok/s: 6.060789\n")
assert(s == "The end." and math.abs(t - 6.060789) < 1e-9, s)
s, t = p.parse("Lily smiled.\nachieved tok/s: 12")
assert(s == "Lily smiled." and t == 12)
print("parse ok")
