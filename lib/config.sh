# Validate .claude/kit.json against slice declarations and resolve parameters.
# Sourced after lib/common.sh; uses only bash, git and jq.

# The jq program. Inputs: --slurpfile cfg (kit.json), --slurpfile sl (one
# {name, decl} per slice directory found), --rawfile paths (dest<TAB>src<TAB>slice
# lines). Emits {errs: [...], result: {...}}.
_CONFIG_JQ='
def refs: [scan("\\{\\{kit\\.([A-Za-z0-9_]+)\\}\\}") | .[0]];
def subst($r): gsub("\\{\\{kit\\.(?<n>[A-Za-z0-9_]+)\\}\\}"; $r[.n]);
def hs($o): . as $k | $o | has($k);
def good($d): (.value | type == "string") and (. as $e | ($d[$e.key].pattern // null) as $p | $p == null or ($e.value | test($p)));
def strs: type == "array" and all(.[]; type == "string");

$cfg[0] as $k
| if ($k | type) != "object" then {errs: ["CONFIG .claude/kit.json must be a JSON object"]} else
  ["format", "slices", "params", "exclude"] as $allowed
  | [ $k | keys_unsorted[] | select(. as $x | $allowed | index($x) | not)
      | "CONFIG unknown key \"\(.)\" in .claude/kit.json" ] as $e_keys
  | (if $k.format == 1 then []
     else ["CONFIG format \(($k.format // "missing") | tostring) is not supported; this kit reads format 1 (see CHANGELOG)"] end) as $e_fmt
  | (if ($k.slices | strs) then [] else ["CONFIG \"slices\" must be an array of strings"] end) as $e_t1
  | (if (($k.params // {}) | type) == "object" then [] else ["CONFIG \"params\" must be an object"] end) as $e_t2
  | (if (($k.exclude // []) | strs) then [] else ["CONFIG \"exclude\" must be an array of strings"] end) as $e_t3
  | (if ($e_t1 | length) == 0 then $k.slices else [] end) as $slices
  | (if ($e_t2 | length) == 0 then ($k.params // {}) else {} end) as $params
  | (if ($e_t3 | length) == 0 then ($k.exclude // []) else [] end) as $exclude
  | ($sl | map({(.name): .decl}) | add // {}) as $decl
  | ($slices | map(select(hs($decl)))) as $enabled
  | ($slices | map(select(hs($decl) | not)) | map("CONFIG unknown slice \"\(.)\"")) as $e_unk
  | (if ($slices | length) != ($slices | unique | length) then ["CONFIG a slice is listed more than once"] else [] end) as $e_dup
  | (if ($e_t1 | length) == 0 and ($slices | index("core") | not) then ["CONFIG slice \"core\" is mandatory"] else [] end) as $e_core
  | [ $enabled[] as $s | ($decl[$s].requires // [])[] as $r
      | select($enabled | index($r) | not) | "CONFIG \($s) requires \($r)" ] as $e_req
  | ( [ $enabled[] as $s | ($decl[$s].conflicts // [])[] as $c
        | select($enabled | index($c)) | [$s, $c] ]
      | unique_by(sort) | map("CONFIG \(.[0]) conflicts with \(.[1])") ) as $e_con
  # parameter declarations, first declaration wins
  | [ $enabled[] as $s | ($decl[$s].params // {}) | to_entries[]
      | {name: .key, slice: $s} + (.value | if type == "object" then . else {} end) ] as $pd
  | (reduce $pd[] as $p ({}; if has($p.name) then . else .[$p.name] = $p end)) as $declared
  | ( [ $pd | group_by(.name)[] | select(length > 1)
        | select(map(del(.slice)) | unique | length > 1)
        | "CONFIG param \(.[0].name) is declared differently by \(map(.slice) | join(" and "))" ] ) as $e_decl
  | [ $declared[] | select(.pattern == null) | "CONFIG param \(.name) (\(.slice)) declares no pattern" ] as $e_nopat
  | [ $declared[] | select(.required == true and (.name | hs($params) | not))
      | "CONFIG param \(.name) (\(.slice)) is required" ] as $e_required
  | [ $params | keys_unsorted[] | select(hs($declared) | not)
      | "CONFIG unknown param \"\(.)\" (no enabled slice declares it)" ] as $e_uparam
  | ( [ $params | to_entries[] | select(.key | hs($declared)) | select(.value | type != "string")
        | "CONFIG param \(.key) must be a string" ] ) as $e_type
  | ( [ $params | to_entries[] | select(.key | hs($declared)) | select(.value | type == "string")
        | select(good($declared) | not)
        | "CONFIG param \(.key) value does not match its pattern" ] ) as $e_pat
  | ( {
        res: ($params | with_entries(select((.key | hs($declared)) and (.value | type == "string") and good($declared)))),
        fail: ( [ $declared[] | select(.required == true and (.name | hs($params) | not)) | .name ]
              + [ $params | to_entries[] | select(.key | hs($declared))
                  | select((.value | type != "string") or (good($declared) | not))
                  | .key ] ),
        pend: ( [ $declared[] | select((.name | hs($params) | not) and (.default | type) == "string")
                  | {(.name): .default} ] | add // {} ),
        errs: [], changed: true
      }
      | until(.changed | not;
          reduce (.pend | keys_unsorted[]) as $n (.changed = false;
            . as $st | $st.pend[$n] as $t | ($t | refs) as $rf
            | if any($rf[]; . as $x | ($st.fail | index($x)) != null) then
                .fail += [$n] | del(.pend[$n]) | .changed = true
              elif all($rf[]; . as $x | $st.res | has($x)) then
                ($t | subst($st.res)) as $v
                | del(.pend[$n]) | .changed = true
                | if ($declared[$n].pattern // null) == null or ($v | test($declared[$n].pattern)) then .res[$n] = $v
                  else .fail += [$n] | .errs += ["CONFIG param \($n) value does not match its pattern"] end
              else . end))
    ) as $fx
  | [ $fx.pend | to_entries[] | .key as $n | (.value | refs) as $rf
      | ( [ $rf[] | select(hs($declared) | not) ] ) as $unk
      | if ($unk | length) > 0 then "CONFIG param \($n) default refers to unknown param \($unk | join(", "))"
        else "CONFIG param \($n) default cannot be resolved (circular or unset: \([ $rf[] | select(hs($fx.res) | not) ] | join(", ")))" end ] as $e_unres
  | ($paths | split("\n") | map(select(. != "") | split("\t"))) as $pl
  | [ $pl | group_by(.[0])[] | select(length > 1) | .[0] as $f | .[1:][]
      | "CONFIG \($f[0]) is rendered by both \($f[2]) and \(.[2])" ] as $e_dest
  | {
      errs: ($e_fmt + $e_keys + $e_t1 + $e_t2 + $e_t3 + $e_dup + $e_unk + $e_core + $e_req + $e_con
             + $e_decl + $e_nopat + $e_required + $e_uparam + $e_type + $e_pat + $fx.errs + $e_unres + $e_dest),
      result: {
        slices: $enabled,
        params: ($fx.res | to_entries | sort_by(.key) | from_entries),
        exclude: $exclude,
        headings: ([ $enabled[] as $s | select($decl[$s].headings != null) | {($s): $decl[$s].headings} ] | add // {}),
        set: ([ $enabled[] | $decl[.].set // {} ] | add // {}),
        forbid: [ $enabled[] as $s | ($decl[$s].forbid // [])[] | . + {slice: $s} ],
        paths: $pl
      }
    }
  end
'

# config_resolve <tree> <out.json>: <tree> holds an extracted slices/.
# Needs KITJSON (ctx_consumer). Prints CONFIG lines and returns 1 on problems.
config_resolve() {
  local tree="$1" out="$2" work name dir f n
  [ -f "$KITJSON" ] || { say "CONFIG .claude/kit.json is missing"; return 1; }
  jq -e . "$KITJSON" >/dev/null 2>&1 || { say "CONFIG .claude/kit.json is not valid JSON"; return 1; }
  work="$(mktemp -d)" || return 2
  : > "$work/sl.jsonl"
  : > "$work/paths.tsv"
  while IFS= read -r name; do
    case "$name" in '' | *[!A-Za-z0-9_-]*) continue ;; esac
    dir="$tree/slices/$name"
    [ -d "$dir" ] || continue
    if [ -f "$dir/slice.json" ]; then
      jq -c --arg n "$name" '{name: $n, decl: .}' "$dir/slice.json" >> "$work/sl.jsonl" \
        || { rm -rf "$work"; say "CONFIG slices/$name/slice.json is not valid JSON"; return 1; }
    else
      jq -nc --arg n "$name" '{name: $n, decl: {}}' >> "$work/sl.jsonl"
    fi
    (
      cd "$dir" || exit 1
      shopt -s nullglob
      export LC_ALL=C
      for f in rules/*.md; do
        printf '.claude/rules/kit/%s\t%s\t%s\n' "${f#rules/}" "slices/$name/$f" "$name"
      done
      for f in skills/*/SKILL.md; do
        printf '.claude/skills/%s\t%s\t%s\n' "${f#skills/}" "slices/$name/$f" "$name"
      done
      for f in hooks/*.sh; do
        printf '.claude/hooks/kit/%s\t%s\t%s\n' "${f#hooks/}" "slices/$name/$f" "$name"
      done
    ) >> "$work/paths.tsv"
  done < <(jq -r '(.slices // []) | if type == "array" then .[] | strings else empty end' "$KITJSON")
  if ! jq -n --slurpfile cfg "$KITJSON" --slurpfile sl "$work/sl.jsonl" --rawfile paths "$work/paths.tsv" \
      "$_CONFIG_JQ" > "$work/res.json" 2> "$work/err"; then
    cat "$work/err" >&2
    rm -rf "$work"
    return 2
  fi
  n="$(jq '.errs | length' "$work/res.json")"
  if [ "$n" != 0 ]; then
    jq -r '.errs[]' "$work/res.json"
    rm -rf "$work"
    return 1
  fi
  jq '.result' "$work/res.json" > "$out"
  rm -rf "$work"
  return 0
}
