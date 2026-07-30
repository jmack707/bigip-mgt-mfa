# Shared object list for the mutable half of the APM build. apm-build.sh deletes these
# before recreating them so a re-run is clean, and teardown.sh deletes the same set — one
# list, so the two cannot drift.
#
# Order matters: policy/profile first, then the items they reference, or TMOS refuses the
# delete with "is in use".
wl_apm_objects() { # wl_apm_objects <prefix> <partition>
  local p="$1" part="$2"
  cat <<EOF
ltm/virtual/~${part}~${p}-vs
apm/profile/access/~${part}~${p}
apm/policy/access-policy/~${part}~${p}
apm/policy/policy-item/~${part}~${p}_ent
apm/policy/policy-item/~${part}~${p}_act_logon
apm/policy/policy-item/~${part}~${p}_act_ldapauth
apm/policy/policy-item/~${part}~${p}_act_oauth
apm/policy/policy-item/~${part}~${p}_act_ssomap
apm/policy/policy-item/~${part}~${p}_act_resourceassign
apm/policy/policy-item/~${part}~${p}_end_allow
apm/policy/policy-item/~${part}~${p}_end_deny
apm/policy/agent/logon-page/~${part}~${p}_act_logon_ag
apm/policy/agent/aaa-ldap/~${part}~${p}_act_ldapauth_ag
apm/policy/agent/aaa-oauth/~${part}~${p}_act_oauth_ag
apm/policy/agent/variable-assign/~${part}~${p}_act_ssomap_ag
apm/policy/agent/resource-assign/~${part}~${p}_act_resourceassign_ag
apm/policy/agent/ending-allow/~${part}~${p}_end_allow_ag
apm/policy/agent/ending-deny/~${part}~${p}_end_deny_ag
EOF
}
