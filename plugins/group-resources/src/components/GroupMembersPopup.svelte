<script lang="ts">
  import { createEventDispatcher, onMount } from "svelte"
  import { type AccountUuid } from "@hcengineering/core"
  import presentation, { getClient } from "@hcengineering/presentation"
  import { ActionIcon, IconClose, Button, EditBox } from "@hcengineering/ui"
  import groupPlugin from "@hcengineering/group"
  import contact, { type Employee } from "@hcengineering/contact"

  export let members: AccountUuid[] = []
  export let groupName: string = ""

  const dispatch = createEventDispatcher()
  const client = getClient()

  let search: string = ""
  let employees: Employee[] = []
  let selectedMembers: AccountUuid[] = [...members]

  onMount(async () => {
    try {
      employees = await client.findAll(contact.mixin.Employee, { active: true })
    } catch (e) {
      console.error("Failed to load employees", e)
    }
  })

  $: filteredEmployees = search
    ? employees.filter((e) => {
        const name = (e.name ?? "").toLowerCase()
        return name.includes(search.toLowerCase())
      })
    : employees

  function toggleMember (personUuid: AccountUuid | undefined): void {
    if (personUuid == null) return
    if (selectedMembers.includes(personUuid)) {
      selectedMembers = selectedMembers.filter((m) => m !== personUuid)
    } else {
      selectedMembers = [...selectedMembers, personUuid]
    }
  }

  function isSelected (personUuid: AccountUuid | undefined): boolean {
    if (personUuid == null) return false
    return selectedMembers.includes(personUuid)
  }

  function done (): void {
    dispatch("close", selectedMembers)
  }
</script>

<div style="width: 26rem;" class="flex-col bg-white rounded-lg">
  <div class="flex-between p-3 border-b">
    <span style="font-weight: 500; font-size: 1rem;">{groupPlugin.string.GroupMembers}</span>
    <ActionIcon icon={IconClose} size={"small"} action={() => { dispatch("close", selectedMembers) }} />
  </div>
  <div class="p-3 border-b">
    <EditBox bind:value={search} placeholder={presentation.string.Search} kind="ghost" fullSize />
  </div>
  <div style="max-height: 20rem; overflow-y: auto;">
    {#each filteredEmployees as employee (employee._id)}
      <div
        class="flex-row-center p-2"
        class:sel={isSelected(employee.personUuid)}
        on:click={() => toggleMember(employee.personUuid)}
        role="button"
        tabindex="0"
        on:keypress={(e) => { if (e.key === "Enter") toggleMember(employee.personUuid) }}
      >
        <span class="p-1">{employee.name}</span>
      </div>
    {/each}
  </div>
  <div class="flex-row-reverse p-3 border-t">
    <Button on:click={() => done()} label={presentation.string.Ok} kind="primary" size="medium" />
  </div>
</div>

<style lang="scss">
  .p-3 { padding: 0.75rem; }
  .p-2 { padding: 0.5rem; }
  .p-1 { padding: 0.25rem; }
  .border-b { border-bottom: 1px solid var(--theme-divider-color); }
  .border-t { border-top: 1px solid var(--theme-divider-color); }
  .sel { background-color: var(--theme-accent-color); color: var(--theme-button-contrast-color); }
  .bg-white { background: var(--theme-popup-color); }
  .rounded-lg { border-radius: 0.5rem; }
</style>