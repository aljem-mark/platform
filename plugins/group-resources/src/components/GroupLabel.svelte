<script lang="ts">
  import { type Group } from "@hcengineering/group"
  export let group: Group | undefined
  export let projectMembers: string[] = []

  let ef = group != null ? group.members.filter(function(m: string) { return projectMembers.includes(m) }) : []

  $: effectiveMembers = ef
  $: displayText = group != null ? group.name + " (" + effectiveMembers.length + " member" + (effectiveMembers.length !== 1 ? "s" : "") + ")" : ""
</script>

{#if group != null}
  <span class="group-label">{displayText}</span>
{/if}
