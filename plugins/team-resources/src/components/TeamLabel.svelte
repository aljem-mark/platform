<script lang="ts">
  import { type Team } from "@hcengineering/team"
  export let team: Team | undefined
  export let projectMembers: string[] = []

  let ef = team != null ? team.members.filter(function(m) { return projectMembers.includes(m) }) : []

  $: effectiveMembers = ef
  $: displayText = team != null ? team.name + " (" + effectiveMembers.length + " member" + (effectiveMembers.length !== 1 ? "s" : "") + ")" : ""
</script>

{#if team != null}
  <span class="team-label">{displayText}</span>
{/if}
