<script lang="ts">
  import { type Ref } from '@hcengineering/core'
  import { type Group } from '@hcengineering/group'
  import { showPopup, SelectPopup } from '@hcengineering/ui'

  export let value: Ref<Group> | undefined
  export let groups: Group[] = []
  export let kind: string = 'regular'
  export let size: string = 'large'
  export let label: string = 'Group'
  export let placeholder: string = 'Group'
  export let showTooltip: any = undefined

  let selectedGroup = value != null ? groups.find(t => t._id === value) : undefined

  function handleSelect (evt: MouseEvent): void {
    showPopup(
      SelectPopup,
      {
        value: value ?? '' as any,
        items: [
          [{ id: '' as any, label: 'None' }],
          groups.map(t => ({ id: t._id, label: t.name }))
        ]
      },
      'top',
      (result?: string) => {
        if (result !== undefined) {
          const res = result as unknown as Ref<Group>
          value = res === ("" as unknown as Ref<Group>) ? undefined : res
          selectedGroup = value != null ? groups.find(t => t._id === value) : undefined
        }
      }
    )
  }
</script>

<div class="group-box-wrapper" on:click={handleSelect} role="button" tabindex="0">
  {#if selectedGroup != null}
    <span class="group-name">{selectedGroup.name}</span>
  {:else}
    <span class="placeholder">{placeholder}</span>
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
