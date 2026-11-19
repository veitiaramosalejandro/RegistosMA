. (Join-Path $PSScriptRoot 'Tooltip_Layout.ps1')
# Shared action descriptions; existing dynamic details remain visible below them.
function Get-ButtonActionDescription {
    param($Button)
    $text=([string]$Button.Text).Replace('&','').Trim()
    if(-not $text){$text=[string]$Button.AccessibleName}
    if($Button.Name -eq 'PreviewPlannedExtraction'){
        if($script:UiLanguage -eq 'pt'){return 'Fecha esta janela, coloca o início e o fim da extração selecionada nos marcadores e inicia a pré-visualização.'}
        return 'Close this window, set the start and end markers to the selected extraction and start its preview.'
    }
    if($Button.Name -in @('PreviewExtraction','RestartExtractionPreview') -and $Button.AccessibleName){$text=[string]$Button.AccessibleName}
    $text=$text -replace '/program(?:as|a|s)?\b',''
    if($Button.Name -eq 'Seek' -and $text -match '^(Posicionar|Position)$'){$text='Position at context/program'}
    $pt=$script:UiLanguage -eq 'pt'
    if($text -eq [string][char]0x25B6){$text='Resume'}
    if($text -eq [string][char]0x23F8 -or $text -eq '||'){$text='Pause'}
    $rules=@(
        @('Pré-visualizar extração|Preview extraction','Reproduz o intervalo entre as marcas de início e fim e pausa no fim, sem criar ficheiros.','Play the interval between the start and end markers and pause at its end, without creating files.'),
        @('Parar pré-visualização|Stop preview','Interrompe a pré-visualização e pausa na posição atual.','Stop the preview and pause at the current position.'),
        @('Pausar pré-visualização|Pause preview','Pausa a pré-visualização na posição atual. Use retomar para continuar até à marca de fim.','Pause the preview at the current position. Resume to continue to the end marker.'),
        @('Retomar pré-visualização|Resume preview','Retoma a pré-visualização da posição atual até à marca de fim.','Resume preview from the current position to the end marker.'),
        @('Recomeçar pré-visualização|Restart preview','Recomeça a pré-visualização na marca de início, mesmo que esteja em pausa ou em reprodução.','Restart preview at the start marker, whether paused or playing.'),
        @('^(Resume|Retomar|Play)$','Retoma a reprodução a partir da posição atual.','Resume playback from the current position.'),
        @('^(Pause|Pausar|Pause / Resume|Pausar / Retomar)$','Pausa ou retoma a reprodução sem alterar a posição.','Pause or resume playback without changing position.'),
        @('Reajustar|Readjust','Ajusta as alturas do vídeo e dos gráficos ao tamanho da janela.','Fit video and chart heights to the window.'),
        @('Ocultar.*(visualiza|vídeo)|Hide.*(visual|video)','Oculta a zona de visualização para dar mais espaço à lista de eventos.','Hide the visualization area to give the event list more space.'),
        @('Mostrar.*visualiza|Restaurar visualiza|Show.*visual|Restore visualization','Volta a mostrar a zona de visualização.','Show the visualization area again.'),
        @('Posicionar no contexto|Posicionar no início do contexto|Position at context','Move a reprodução para o início do contexto/programa selecionado.','Move playback to the start of the selected context/program.'),
        @('Posicionar no evento|Position at event','Move a reprodução para o instante do evento selecionado.','Move playback to the selected event time.'),
        @('Posicionar no tempo|Position in time','Permite indicar o instante para onde pretende mover a reprodução.','Enter the time to move playback to.'),
        @('Registar evento|Record event|^Anotar$|^Annotate$','Regista um evento no instante atual e permite indicar a classificação, o estado e as notas.','Record an event at the current time with rating, state and notes.'),
        @('Editar evento|Edit event','Abre o evento selecionado para alterar os seus dados.','Open the selected event to edit its details.'),
        @('Eliminar evento|Delete event','Elimina os eventos selecionados após confirmação.','Delete the selected events after confirmation.'),
        @('Adicionar neste momento|Add at current time','Cria um contexto/programa no instante atual da reprodução.','Create a context/program at the current playback time.'),
        @('^Contextos$|^Contexts$','Abre a lista de contextos/programas para consultar, adicionar, editar ou eliminar.','Open the context/program list to view, add, edit or delete contexts/programs.'),
        @('^Contexto$|^Context$','Abre os dados do contexto/programa da gravação.','Open the recording context/program details.'),
        @('^Filtros$|^Filters$','Abre os filtros de análise e os respetivos parâmetros.','Open analysis filters and their parameters.'),
        @('Atualizar a partir do contexto|Update from recording context','Preenche os parâmetros dos filtros com os dados do contexto/programa da gravação.','Fill filter parameters from the recording context/program.'),
        @('Aplicar e guardar|Apply and save','Aplica os parâmetros e guarda-os para esta gravação.','Apply the parameters and save them for this recording.'),
        @('Marcar.*início|Mark start','Marca o instante atual como início da extração.','Mark the current time as the extraction start.'),
        @('Marcar.*fim|Mark end','Marca o instante atual como fim da extração.','Mark the current time as the extraction end.'),
        @('Limpar.*marc|Clear markers','Remove as marcas de início e fim da extração.','Clear the extraction start and end markers.'),
        @('Cancelar extra|Cancel extraction','Cancela a extração em curso.','Cancel the extraction currently in progress.'),
        @('Eliminar.*extra|Delete extractions','Elimina as pastas das extrações selecionadas após confirmação.','Delete selected extraction folders after confirmation.'),
        @('Abrir pasta|Open.*folder','Abre no Explorador a pasta indicada ou selecionada.','Open the indicated or selected folder in File Explorer.'),
        @('Extrair|Extract','Extrai o intervalo selecionado para uma nova gravação.','Extract the selected interval into a new recording.'),
        @('Extrações|Recording extraction','Abre a gestão das extrações e dos intervalos marcados.','Open extraction management and marked intervals.'),
        @('Escolher pasta|Choose folder','Permite escolher a pasta a utilizar nesta janela.','Choose the folder to use in this window.'),
        @('Abrir grava|Open recording','Abre a gravação selecionada para reprodução e análise.','Open the selected recording for playback and analysis.'),
        @('Renomear|Rename','Altera o nome da gravação ou da entrada selecionada.','Rename the selected recording or entry.'),
        @('Atualizar lista de dispositivos|Refresh device list','Volta a detetar as câmaras e os dispositivos de áudio disponíveis.','Scan again for available cameras and audio devices.'),
        @('Remover câmara|Remove camera','Retira a câmara selecionada da configuração de gravação.','Remove the selected camera from the recording setup.'),
        @('Mover para cima|Move up','Move a câmara selecionada uma posição para cima na ordem.','Move the selected camera one position up.'),
        @('Mover para baixo|Move down','Move a câmara selecionada uma posição para baixo na ordem.','Move the selected camera one position down.'),
        @('Parar grava|Stop recording','Termina a gravação em curso e guarda os dados capturados.','Stop the current recording and save the captured data.'),
        @('Iniciar grava|Start recording','Inicia uma gravação com os dispositivos e parâmetros configurados.','Start recording with the configured devices and parameters.'),
        @('Remover temporizador|Remove timer','Remove a paragem automática definida pelo temporizador.','Remove the automatic stop configured by the timer.'),
        @('Temporizador|Timer','Define quando a gravação deve parar automaticamente.','Set when recording should stop automatically.'),
        @('Agendamentos|Schedules','Abre a gestão de horários de início e fim das gravações.','Manage scheduled recording start and end times.'),
        @('Configura|Settings','Abre as opções e os parâmetros desta janela.','Open settings and parameters for this window.'),
        @('Copiar tempo|Copy time','Copia o instante atual para o campo de tempo desta janela.','Copy the current time into this window''s time field.'),
        @('Copiar|Copy','Copia o valor indicado para o campo de destino.','Copy the indicated value into the destination field.'),
        @('^Guardar$|^Save$','Guarda as alterações efetuadas nesta janela.','Save the changes made in this window.'),
        @('^Aplicar$|^Apply$','Aplica os valores definidos nesta janela.','Apply the values configured in this window.'),
        @('^Confirmar$|^Confirm$','Confirma a operação indicada nesta janela.','Confirm the operation shown in this window.'),
        @('^Cancelar$|^Cancel$','Fecha esta janela sem confirmar as alterações.','Close this window without confirming changes.'),
        @('^Fechar$|^Close$','Fecha esta janela e regressa à anterior.','Close this window and return to the previous one.'),
        @('^Adicionar$|^Add$','Cria uma nova entrada na lista apresentada.','Create a new entry in the displayed list.'),
        @('^Editar$|^Edit$','Abre a entrada selecionada para alterar os seus dados.','Open the selected entry to edit its details.'),
        @('Eliminar|Remover|Delete|Remove','Remove as entradas selecionadas da lista.','Remove the selected entries from the list.'),
        @('^Posicionar$|^Position$','Move a reprodução para o instante da entrada selecionada.','Move playback to the selected entry time.'),
        @('Atualizar|Refresh','Volta a ler os dados e atualiza a lista apresentada.','Reload the data and refresh the displayed list.')
    )
    foreach($rule in $rules){if($text -match $rule[0]){if($pt){return $rule[1]}else{return $rule[2]}}}
    if($Button.AccessibleDescription){return [string]$Button.AccessibleDescription}
    if($pt){return ('Executa a ação indicada neste botão: '+$text+'.')}
    return ('Perform the action indicated by this button: '+$text+'.')
}
function Update-ButtonActionTooltip {
    param($Button)
    $form=$Button.FindForm();if(-not $form){return}
    $tip=$null
    if($form.Tag -and $form.Tag.Tooltip -is [Windows.Forms.ToolTip]){$tip=$form.Tag.Tooltip}
    if($script:RecordingUi){
        if($Button -eq $script:RecordingUi.Start -and $script:RecordingUi.ToggleTip){$tip=$script:RecordingUi.ToggleTip}
        elseif($Button -eq $script:RecordingUi.TimerButton -and $script:RecordingUi.ScheduleTip){$tip=$script:RecordingUi.ScheduleTip}
    }
    if(-not $tip){
        if(-not $form.PSObject.Properties['ActionTooltips']){
            $tip=New-Object MachiningMonitor.WrappingToolTip;$tip.AutoPopDelay=15000;$tip.InitialDelay=600;$tip.ReshowDelay=150
            $form | Add-Member NoteProperty ActionTooltips $tip
            $form.Add_Disposed({$this.ActionTooltips.Dispose()})
        }
        $tip=$form.ActionTooltips
    }
    if($Button.ActionTooltipProvider -and $Button.ActionTooltipProvider -ne $tip){$Button.ActionTooltipProvider.SetToolTip($Button,$null)}
    $Button.ActionTooltipProvider=$tip
    $description=Get-ButtonActionDescription $Button
    $old=$tip.GetToolTip($Button)
    if($old -and $old -ne $Button.ActionTooltipText -and $old -ne $description){$description+=[Environment]::NewLine+$old}
    if($old -ne $description){$tip.SetToolTip($Button,$description)}
    $Button.ActionTooltipText=$description
}
function Register-ButtonActionTooltip {
    param($Button)
    if($Button.PSObject.Properties['ActionTooltipText']){return}
    $Button | Add-Member NoteProperty ActionTooltipText ''
    $Button | Add-Member NoteProperty ActionTooltipProvider $null
    $Button.Add_ParentChanged({Update-ButtonActionTooltip $this})
    $Button.Add_TextChanged({Update-ButtonActionTooltip $this})
    $Button.Add_MouseEnter({Update-ButtonActionTooltip $this})
}
