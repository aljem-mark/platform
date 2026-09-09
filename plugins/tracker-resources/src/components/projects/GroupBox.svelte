<script lang="ts">
  import { type Ref } from '@hcengineering/core'
  import { type Group } from '@hcengineering/group'
  import { showPopup, SelectPopup, Label } from '@hcengineering/ui'
  import { type IntlString } from '@hcengineering/platform'

  export let value: Ref<Group> | undefined
  export let groups: Group[] = []
  export let kind: string = 'regular'
  export let size: string = 'large'
  export let label: string = 'Group'
  export let placeholder: IntlString = '' as IntlString
  export let showTooltip: any = undefined

  let selectedGroup = value != null ? groups.find(t => t._id === value) : undefined

  function handleSelect (evt: MouseEvent): void {
    showPopup(
      SelectPopup,
      {
        value: [
          { id: '' as unknown as (string | number | null), text: 'None', isSelected: value == null },
          ...groups.map(t => ({
            id: t._id as string,
            text: t.name,
            isSelected: t._id === value
          }))
        ]
      },
      'top',
      (result?: { id: string | number | null }) => {
        if (result !== undefined && result.id !== undefined) {
          const groupId = result.id as string
          value = groupId === "" ? undefined : groupId as unknown as Ref<Group>
          selectedGroup = value != null ? groups.find(t => t._id === value) : undefined
          if (selectedGroup == null && value != null) {
            value = undefined
          }
        }
      }
    )
  }
</script>

<div class="group-box-wrapper" on:click={handleSelect} role="button" tabindex="0">
  {#if selectedGroup != null}
    <span class="group-name">{selectedGroup.name}</span>
  {:else}
    <span class="placeholder"><Label label={placeholder} /></span>
  {/if}
</div>

<style>
  .group-box-wrapper {
    display: flex;
    align-items: center;
    padding: 0.5rem 1rem;
    border: 1px solid var(--theme-button-border);
    border-radius: 0.25rem;
    cursor: pointer;
    min-height: 2.5rem;
    background: var(--theme-bg-color);
  }
  .group-box-wrapper:hover {
    border-color: var(--theme-button-hovered);
  }
  .group-name {
    color: var(--theme-caption-color);
    font-weight: 500;
  }
  .placeholder {
    color: var(--theme-text-placeholder-color);
    font-style: italic;
  }
</style>
