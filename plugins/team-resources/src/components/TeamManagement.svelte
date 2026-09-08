<script lang="ts">
  import { onMount } from "svelte"
  import { getClient } from "@hcengineering/presentation"
  import { type Team } from "@hcengineering/team"
  import teamPlugin from "@hcengineering/team"
  let teams: Team[] = []
  let loading = true
  onMount(async () => {
    const client = getClient()
    try { teams = await client.findAll(teamPlugin.class.Team, {}) }
    catch (e) { console.error("Failed to load teams", e) }
    finally { loading = false }
  })
</script>

<div class="team-management">
  <h2>Team Management</h2>
  {#if loading}<p>Loading...</p>{:else if teams.length === 0}<p>No teams created yet.</p>{:else}
    {#each teams as team}
      <div class="team-item"><span>{team.name}</span><span>({team.members.length} members)</span></div>
    {/each}
  {/if}
</div>
