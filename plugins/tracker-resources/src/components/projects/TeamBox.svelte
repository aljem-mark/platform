<script lang="ts">
  import { type Ref } from '@hcengineering/core'
  import { type Team } from '@hcengineering/team'
  import { showPopup, SelectPopup } from '@hcengineering/ui'

  export let value: Ref<Team> | undefined
  export let teams: Team[] = []
  export let kind: string = 'regular'
  export let size: string = 'large'
  export let label: string = 'Team'
  export let placeholder: string = 'Team'
  export let showTooltip: any = undefined

  let selectedTeam = value != null ? teams.find(t => t._id === value) : undefined

  function handleSelect (evt: MouseEvent): void {
    showPopup(
      SelectPopup,
      {
        value: value ?? '' as any,
        items: [
          [{ id: '' as any, label: 'None' }],
          teams.map(t => ({ id: t._id, label: t.name }))
        ]
      },
      'top',
      (result?: string) => {
        if (result !== undefined) {
          const res = result as unknown as Ref<Team>
          value = res === ("" as unknown as Ref<Team>) ? undefined : res
          selectedTeam = value != null ? teams.find(t => t._id === value) : undefined
        }
      }
    )
  }
</script>

<div class="team-box-wrapper" on:click={handleSelect} role="button" tabindex="0">
  {#if selectedTeam != null}
    <span class="team-name">{selectedTeam.name}</span>
  {:else}
    <span class="placeholder">{placeholder}</span>
  {/if}
</div>

<style>
  .team-box-wrapper {
    display: flex;
    align-items: center;
    padding: 0.5rem 1rem;
    border: 1px solid var(--theme-button-border);
    border-radius: 0.25rem;
    cursor: pointer;
    min-height: 2.5rem;
    background: var(--theme-bg-color);
  }
  .team-box-wrapper:hover {
    border-color: var(--theme-button-hovered);
  }
  .team-name {
    color: var(--theme-caption-color);
    font-weight: 500;
  }
  .placeholder {
    color: var(--theme-text-placeholder-color);
    font-style: italic;
  }
</style>
