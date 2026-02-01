#!/bin/bash

# Script para encontrar e resolver duplicatas do Nefarious
# Compara arquivos entre as pastas intermediárias e a pasta de destino final

# Carrega variáveis de ambiente ou usa padrões
DOWNLOADS="${NEFARIOUS_DOWNLOADS_PATH:-/Users/paulista/Downloads}"
FINAL="${NEFARIOUS_FINAL_PATH:-$DOWNLOADS/movies}"
UNPROCESSED="${NEFARIOUS_UNPROCESSED_PATH:-$DOWNLOADS/.nefarious-unprocessed-downloads/movies}"
INCOMPLETE="${NEFARIOUS_INCOMPLETE_PATH:-$DOWNLOADS/.incomplete}"
TRANSMISSION_CONTAINER="${NEFARIOUS_TRANSMISSION_CONTAINER:-nefarious-transmission-1}"
CELERY_CONTAINER="${NEFARIOUS_CELERY_CONTAINER:-nefarious-celery-1}"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para formatar tamanho em bytes para formato legível
format_size() {
    local size=$1
    if [ $size -ge 1073741824 ]; then
        echo "$(echo "scale=2; $size/1073741824" | bc) GB"
    elif [ $size -ge 1048576 ]; then
        echo "$(echo "scale=2; $size/1048576" | bc) MB"
    elif [ $size -ge 1024 ]; then
        echo "$(echo "scale=2; $size/1024" | bc) KB"
    else
        echo "$size B"
    fi
}

# Função para obter tamanho de uma pasta/arquivo
get_size() {
    local path="$1"
    if [ -d "$path" ]; then
        du -sk "$path" 2>/dev/null | cut -f1 | awk '{print $1 * 1024}'
    elif [ -f "$path" ]; then
        stat -f%z "$path" 2>/dev/null
    else
        echo "0"
    fi
}

# Função para obter inode de um arquivo/pasta
get_inode() {
    local path="$1"
    stat -f%i "$path" 2>/dev/null
}

# Verifica se dois arquivos são hard links (mesmo inode)
is_hardlink() {
    local file1="$1"
    local file2="$2"
    
    local inode1=$(get_inode "$file1")
    local inode2=$(get_inode "$file2")
    
    if [ -n "$inode1" ] && [ -n "$inode2" ] && [ "$inode1" == "$inode2" ]; then
        return 0  # true - são hard links
    else
        return 1  # false - são arquivos diferentes
    fi
}

echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     🎬 Nefarious Duplicate Cleaner                         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${YELLOW}📁 Pastas monitoradas:${NC}"
echo -e "   • Final:        $FINAL"
echo -e "   • Unprocessed:  $UNPROCESSED"
echo -e "   • Incomplete:   $INCOMPLETE"
echo -e "   • Transmission: container $TRANSMISSION_CONTAINER"
echo ""

# Verifica se o container do Transmission está rodando
check_transmission_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$TRANSMISSION_CONTAINER"
}

# Lista torrents concluídos no Transmission
list_transmission_completed() {
    if ! check_transmission_running; then
        echo -e "${RED}⚠️  Container $TRANSMISSION_CONTAINER não está rodando${NC}"
        return
    fi
    
    echo -e "${GREEN}▸ Torrents no Transmission:${NC}"
    echo ""
    docker exec "$TRANSMISSION_CONTAINER" transmission-remote -l 2>/dev/null | tail -n +2 | head -n -1 | while read line; do
        id=$(echo "$line" | awk '{print $1}')
        done=$(echo "$line" | awk '{print $2}')
        name=$(echo "$line" | awk '{for(i=10;i<=NF;i++) printf $i" "; print ""}' | sed 's/ *$//')
        
        if [ "$done" == "100%" ]; then
            echo -e "   ${GREEN}✅ [COMPLETO]${NC} $name"
        elif [[ "$done" == *"%" ]]; then
            echo -e "   ${YELLOW}⏳ [$done]${NC} $name"
        fi
    done
    echo ""
}

# Lista arquivos nas pastas dos containers (visão interna)
list_container_folders() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}           📦 VISÃO INTERNA DOS CONTAINERS                 ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # Container Transmission
    if check_transmission_running; then
        echo -e "${GREEN}▸ TRANSMISSION CONTAINER ($TRANSMISSION_CONTAINER):${NC}"
        echo ""
        echo -e "   ${YELLOW}/downloads/.nefarious-unprocessed-downloads/:${NC}"
        docker exec "$TRANSMISSION_CONTAINER" ls -laR /downloads/.nefarious-unprocessed-downloads/ 2>/dev/null | while read line; do
            echo "      $line"
        done
        echo ""
    else
        echo -e "${RED}⚠️  Container $TRANSMISSION_CONTAINER não está rodando${NC}"
    fi
    
    # Container Nefarious (celery)
    CELERY_CONTAINER="nefarious-celery-1"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$CELERY_CONTAINER"; then
        echo -e "${GREEN}▸ NEFARIOUS/CELERY CONTAINER ($CELERY_CONTAINER):${NC}"
        echo ""
        echo -e "   ${YELLOW}/downloads/.nefarious-unprocessed-downloads/:${NC}"
        docker exec "$CELERY_CONTAINER" ls -laR /downloads/.nefarious-unprocessed-downloads/ 2>/dev/null | while read line; do
            echo "      $line"
        done
        echo ""
    else
        echo -e "${RED}⚠️  Container $CELERY_CONTAINER não está rodando${NC}"
    fi
    
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

# Remove torrents concluídos do Transmission (sem deletar arquivos)
clean_transmission_completed() {
    if ! check_transmission_running; then
        echo -e "${RED}⚠️  Container $TRANSMISSION_CONTAINER não está rodando${NC}"
        return
    fi
    
    echo -e "${YELLOW}Removendo torrents 100% concluídos do Transmission...${NC}"
    echo ""
    
    # Obtém lista de IDs de torrents 100% completos
    completed_ids=$(docker exec "$TRANSMISSION_CONTAINER" transmission-remote -l 2>/dev/null | tail -n +2 | head -n -1 | awk '$2 == "100%" {gsub(/\*/, "", $1); print $1}')
    
    count=0
    for id in $completed_ids; do
        name=$(docker exec "$TRANSMISSION_CONTAINER" transmission-remote -t $id -i 2>/dev/null | grep "Name:" | sed 's/.*Name: //')
        echo -e "   🗑️  Removendo torrent: $name"
        docker exec "$TRANSMISSION_CONTAINER" transmission-remote -t $id --remove 2>/dev/null
        count=$((count + 1))
    done
    
    echo ""
    echo -e "${GREEN}✅ Removidos $count torrents do Transmission${NC}"
}

# Arrays para armazenar duplicatas
declare -a duplicates
declare -a dup_locations
total_duplicates=0
total_waste=0

# Função para encontrar duplicatas
find_duplicates() {
    local source_dir="$1"
    local source_name="$2"
    
    [ -d "$source_dir" ] || return
    
    for item in "$source_dir"/*; do
        [ -e "$item" ] || continue
        basename=$(basename "$item")
        
        # Ignora arquivos ocultos do sistema
        [[ "$basename" == .* ]] && continue
        
        # Verifica se existe na pasta final (nome exato ou similar)
        if [ -e "$FINAL/$basename" ]; then
            size_source=$(get_size "$item")
            size_final=$(get_size "$FINAL/$basename")
            
            # Verifica se são hard links (mesmo inode = sem desperdício de espaço)
            inode_source=$(get_inode "$item")
            inode_final=$(get_inode "$FINAL/$basename")
            
            if [ "$inode_source" == "$inode_final" ]; then
                echo -e "${BLUE}🔗 HARD LINK (mesmo arquivo, sem desperdício):${NC}"
                echo -e "   ${YELLOW}Nome:${NC} $basename"
                echo -e "   ${BLUE}Inode:${NC} $inode_source"
                echo -e "   📦 $(format_size $size_source)"
                echo ""
                echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
                echo ""
                continue  # Pula para o próximo, não conta como duplicata
            fi
            
            echo -e "${RED}🔴 DUPLICATA REAL (arquivos diferentes):${NC}"
            echo -e "   ${YELLOW}Nome:${NC} $basename"
            echo ""
            echo -e "   ${BLUE}[1] $source_name:${NC}"
            echo -e "       📍 $item"
            echo -e "       📦 $(format_size $size_source)"
            echo -e "       🔢 Inode: $inode_source"
            echo ""
            echo -e "   ${GREEN}[2] movies (final):${NC}"
            echo -e "       📍 $FINAL/$basename"
            echo -e "       📦 $(format_size $size_final)"
            echo -e "       🔢 Inode: $inode_final"
            echo ""
            
            total_waste=$((total_waste + size_source))
            total_duplicates=$((total_duplicates + 1))
            
            if [ "$1" != "--list-only" ]; then
                echo -e "${YELLOW}   Qual versão deseja remover?${NC}"
                echo -e "   [1] Remover de $source_name"
                echo -e "   [2] Remover de movies (final)"
                echo -e "   [s] Pular esta duplicata"
                echo -e "   [q] Sair do script"
                echo ""
                read -p "   Escolha: " choice
                
                case $choice in
                    1)
                        echo -e "   ${RED}🗑️  Removendo de $source_name...${NC}"
                        trash "$item"
                        echo -e "   ${GREEN}✅ Removido!${NC}"
                        ;;
                    2)
                        echo -e "   ${RED}🗑️  Removendo de movies...${NC}"
                        trash "$FINAL/$basename"
                        echo -e "   ${GREEN}✅ Removido!${NC}"
                        ;;
                    s|S)
                        echo -e "   ${YELLOW}⏭️  Pulado${NC}"
                        ;;
                    q|Q)
                        echo -e "\n${YELLOW}Saindo...${NC}"
                        exit 0
                        ;;
                    *)
                        echo -e "   ${YELLOW}⏭️  Opção inválida, pulando...${NC}"
                        ;;
                esac
            fi
            echo ""
            echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
            echo ""
        fi
    done
}

# Verifica duplicatas entre unprocessed e movies
find_duplicates_by_similarity() {
    local source_dir="$1"
    local source_name="$2"
    
    [ -d "$source_dir" ] || return
    
    for source_item in "$source_dir"/*; do
        [ -e "$source_item" ] || continue
        source_basename=$(basename "$source_item")
        
        # Ignora arquivos ocultos
        [[ "$source_basename" == .* ]] && continue
        
        # Extrai título base (remove qualidade, ano redundante, etc.)
        # Exemplo: "Beast Of War (2025) [1080p]" -> "Beast Of War"
        source_title=$(echo "$source_basename" | sed -E 's/\([0-9]{4}\).*//; s/\[[^]]*\]//g; s/[._-]+/ /g; s/  +/ /g; s/^ +//; s/ +$//' | tr '[:upper:]' '[:lower:]')
        
        for final_item in "$FINAL"/*; do
            [ -e "$final_item" ] || continue
            final_basename=$(basename "$final_item")
            
            [[ "$final_basename" == .* ]] && continue
            
            # Extrai título base do item final
            final_title=$(echo "$final_basename" | sed -E 's/\([0-9]{4}\).*//; s/\[[^]]*\]//g; s/[._-]+/ /g; s/  +/ /g; s/^ +//; s/ +$//' | tr '[:upper:]' '[:lower:]')
            
            # Compara os títulos (ignora se são o mesmo arquivo exato)
            if [ "$source_basename" != "$final_basename" ] && [ "$source_title" == "$final_title" ] && [ -n "$source_title" ]; then
                size_source=$(get_size "$source_item")
                size_final=$(get_size "$final_item")
                
                echo -e "${YELLOW}🟡 POSSÍVEL DUPLICATA (mesmo título):${NC}"
                echo -e "   ${YELLOW}Título detectado:${NC} $source_title"
                echo ""
                echo -e "   ${BLUE}[1] $source_name:${NC}"
                echo -e "       📍 $source_basename"
                echo -e "       📦 $(format_size $size_source)"
                echo ""
                echo -e "   ${GREEN}[2] movies (final):${NC}"
                echo -e "       📍 $final_basename"
                echo -e "       📦 $(format_size $size_final)"
                echo ""
                
                total_waste=$((total_waste + size_source))
                total_duplicates=$((total_duplicates + 1))
                
                if [ "$1" != "--list-only" ]; then
                    echo -e "${YELLOW}   Qual versão deseja remover?${NC}"
                    echo -e "   [1] Remover de $source_name"
                    echo -e "   [2] Remover de movies (final)"
                    echo -e "   [s] Pular"
                    echo -e "   [q] Sair"
                    echo ""
                    read -p "   Escolha: " choice
                    
                    case $choice in
                        1)
                            echo -e "   ${RED}🗑️  Removendo de $source_name...${NC}"
                            trash "$source_item"
                            echo -e "   ${GREEN}✅ Removido!${NC}"
                            ;;
                        2)
                            echo -e "   ${RED}🗑️  Removendo de movies...${NC}"
                            trash "$final_item"
                            echo -e "   ${GREEN}✅ Removido!${NC}"
                            ;;
                        s|S)
                            echo -e "   ${YELLOW}⏭️  Pulado${NC}"
                            ;;
                        q|Q)
                            echo -e "\n${YELLOW}Saindo...${NC}"
                            exit 0
                            ;;
                        *)
                            echo -e "   ${YELLOW}⏭️  Opção inválida, pulando...${NC}"
                            ;;
                    esac
                fi
                echo ""
                echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
                echo ""
            fi
        done
    done
}

# Menu principal
echo -e "${YELLOW}O que deseja fazer?${NC}"
echo "[1] Listar duplicatas (apenas visualizar)"
echo "[2] Listar e remover duplicatas interativamente"
echo "[3] Remover automaticamente das pastas intermediárias (manter movies)"
echo "[4] Listar torrents no Transmission"
echo "[5] Remover torrents concluídos do Transmission"
echo "[q] Sair"
echo ""
read -p "Escolha: " main_choice

case $main_choice in
    1)
        echo ""
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}               📋 LISTANDO DUPLICATAS                       ${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        
        # Duplicatas exatas
        echo -e "${GREEN}▸ Verificando duplicatas EXATAS...${NC}"
        echo ""
        find_duplicates "$UNPROCESSED" "unprocessed" "--list-only"
        find_duplicates "$INCOMPLETE" "incomplete" "--list-only"
        
        # Duplicatas por similaridade de título
        echo -e "${GREEN}▸ Verificando duplicatas por SIMILARIDADE de título...${NC}"
        echo ""
        find_duplicates_by_similarity "$UNPROCESSED" "unprocessed" "--list-only"
        find_duplicates_by_similarity "$INCOMPLETE" "incomplete" "--list-only"
        find_duplicates_by_similarity "$FINAL" "movies" "--list-only"
        
        echo ""
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}📊 Resumo:${NC}"
        echo -e "   Total de duplicatas encontradas: $total_duplicates"
        echo -e "   Espaço potencialmente desperdiçado: $(format_size $total_waste)"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        ;;
    2)
        echo ""
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}            🔧 REMOÇÃO INTERATIVA DE DUPLICATAS            ${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        
        find_duplicates "$UNPROCESSED" "unprocessed"
        find_duplicates "$INCOMPLETE" "incomplete"
        find_duplicates_by_similarity "$UNPROCESSED" "unprocessed"
        find_duplicates_by_similarity "$INCOMPLETE" "incomplete"
        
        echo ""
        echo -e "${GREEN}✅ Processo concluído!${NC}"
        ;;
    3)
        echo ""
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${BLUE}         🤖 REMOÇÃO AUTOMÁTICA DE DUPLICATAS               ${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${YELLOW}Removendo duplicatas das pastas intermediárias...${NC}"
        echo -e "${YELLOW}(mantendo sempre a versão em movies/)${NC}"
        echo ""
        
        removed=0
        
        for source_dir in "$UNPROCESSED" "$INCOMPLETE"; do
            [ -d "$source_dir" ] || continue
            
            for item in "$source_dir"/*; do
                [ -e "$item" ] || continue
                basename=$(basename "$item")
                [[ "$basename" == .* ]] && continue
                
                if [ -e "$FINAL/$basename" ]; then
                    size=$(get_size "$item")
                    echo -e "🗑️  Removendo: $basename ($(format_size $size))"
                    trash "$item"
                    removed=$((removed + 1))
                    total_waste=$((total_waste + size))
                fi
            done
        done
        
        echo ""
        echo -e "${GREEN}✅ Removidas $removed duplicatas${NC}"
        echo -e "${GREEN}📦 Espaço liberado: $(format_size $total_waste)${NC}"
        ;;
    4)
        echo ""
        list_container_folders
        echo ""
        echo -e "${GREEN}▸ Torrents ativos:${NC}"
        list_transmission_completed
        ;;
    5)
        echo ""
        clean_transmission_completed
        ;;
    q|Q)
        echo "Saindo..."
        exit 0
        ;;
    *)
        echo "Opção inválida"
        exit 1
        ;;
esac
