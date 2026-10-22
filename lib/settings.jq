# Settings merge. Run with: jq -n --slurpfile frag F --slurpfile cur C
#   --slurpfile lock L --argjson exclude E --argjson set S -f settings.jq
# frag: the enabled slices' substituted settings.json documents, in slice
# order. cur: the consumer's settings ({} if none). lock: the old lock ({} if
# none). Output: {settings, lockSettings: {kit, adopted}, set}.

def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

# settings -> {allow, ask, deny, hooks: [[event, matcher, handler]]}
def flatten:
  { allow: (.permissions.allow // []),
    ask:   (.permissions.ask // []),
    deny:  (.permissions.deny // []),
    hooks: [ (.hooks // {}) | to_entries[] | .key as $e
             | (.value // [])[] | (.matcher // "") as $m
             | (.hooks // [])[] | [$e, $m, .] ] };

# The inverse of the hooks part, keeping first-seen event and matcher order.
def nest:
  reduce .[] as $t ({};
    $t[0] as $e | $t[1] as $m | $t[2] as $h
    | .[$e] = ((.[$e] // [])
        | if any(.[]; (.matcher // "") == $m)
          then map(if (.matcher // "") == $m then .hooks += [$h] else . end)
          else . + [(if $m == "" then {} else {matcher: $m} end) + {hooks: [$h]}] end));

def merge($cur; $ko; $ao; $kn):
  ($cur - $ko) as $local
  | { list: ($kn + $local + ($ao - $kn) | uniq),
      adopted: (($ao - ($ao - $kn)) + ($local - ($local - $kn)) | uniq) };

def hook_dests: [ $exclude[] | select(startswith(".claude/hooks/")) ];

($cur[0] // {}) as $c
| ($lock[0].settings.kit // {}) as $ko
| ($lock[0].settings.adopted // {}) as $ao
| ($c | flatten) as $cf
| ([ $frag[] | flatten ]) as $fs
| ( reduce ["allow", "ask", "deny"][] as $k ({};
      .[$k] = ([ $fs[][$k][] ] | uniq - [ $exclude[] | select(startswith($k + ":")) | .[($k | length) + 1:] ])) 
    | .hooks = ([ $fs[].hooks[] ] | uniq
                | map(select(. as $t | (.[2].command // "") as $cmd
                             | hook_dests | any(. as $d | $cmd | contains($d)) | not)))
  ) as $kn
| ( reduce ["allow", "ask", "deny"][] as $k ({};
      .[$k] = merge($cf[$k]; ($ko[$k] // []); ($ao[$k] // []); $kn[$k]))
    | .hooks = merge($cf.hooks; ($ko.hooks // []); ($ao.hooks // []); $kn.hooks)
  ) as $m
| ($set | with_entries(select(.key as $k | $exclude | index("set:" + $k) | not))) as $sc
| ( $c
    | reduce ["allow", "ask", "deny"][] as $k (.;
        if ($m[$k].list | length) > 0 then .permissions[$k] = $m[$k].list
        elif (.permissions | type) == "object" and (.permissions | has($k)) then .permissions[$k] = []
        else . end)
    | if ($m.hooks.list | length) > 0 then .hooks = ($m.hooks.list | nest)
      elif has("hooks") then del(.hooks) else . end
    | . + $sc
  ) as $out
| { settings: $out,
    lockSettings: {
      kit: ($kn | {allow, ask, deny, hooks}),
      adopted: ({allow: $m.allow.adopted, ask: $m.ask.adopted, deny: $m.deny.adopted, hooks: $m.hooks.adopted})
    },
    set: $sc }
