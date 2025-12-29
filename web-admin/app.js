// Appwrite Configuration
const APPWRITE_ENDPOINT = 'https://fra.cloud.appwrite.io/v1';
const APPWRITE_PROJECT_ID = '69524ce30037813a6abb';
const DATABASE_ID = '69524e510015a312526b';
const MANUFACTURERS_COLLECTION_ID = 'manufacturers';
const WINGS_COLLECTION_ID = 'wings';
const WING_IMAGES_BUCKET_ID = 'wing-images';

// Initialize Appwrite SDK
const client = new Appwrite.Client();
client
    .setEndpoint(APPWRITE_ENDPOINT)
    .setProject(APPWRITE_PROJECT_ID);

const account = new Appwrite.Account(client);
const databases = new Appwrite.Databases(client);
const storage = new Appwrite.Storage(client);

// State
let manufacturers = [];
let wings = [];
let currentUser = null;
let deleteCallback = null;
let viewMode = 'cards'; // 'cards' or 'list'
let draggedManufacturerId = null;
let draggedWingId = null;

// DOM Elements (initialized in DOMContentLoaded)
let loginSection, mainContent, loginForm, manufacturerForm, wingForm;

// Bootstrap modals
let manufacturerModal, wingModal, deleteModal;

// Initialize
document.addEventListener('DOMContentLoaded', async () => {
    console.log('DOM loaded, initializing...');

    // Get DOM elements
    loginSection = document.getElementById('login-section');
    mainContent = document.getElementById('main-content');
    loginForm = document.getElementById('login-form');
    manufacturerForm = document.getElementById('manufacturer-form');
    wingForm = document.getElementById('wing-form');

    // Initialize Bootstrap modals
    manufacturerModal = new bootstrap.Modal(document.getElementById('manufacturer-modal'));
    wingModal = new bootstrap.Modal(document.getElementById('wing-modal'));
    deleteModal = new bootstrap.Modal(document.getElementById('delete-modal'));

    // Setup event listeners
    loginForm.addEventListener('submit', handleLogin);
    manufacturerForm.addEventListener('submit', handleManufacturerSubmit);
    wingForm.addEventListener('submit', handleWingSubmit);
    document.getElementById('filter-manufacturer').addEventListener('change', renderWings);
    document.getElementById('wing-image').addEventListener('change', handleImagePreview);
    document.getElementById('confirm-delete-btn').addEventListener('click', handleDelete);

    // Check if already logged in
    try {
        console.log('Checking session...');
        currentUser = await account.get();
        console.log('User found:', currentUser.email);
        showMainContent();
    } catch (e) {
        console.log('No session, showing login');
        showLoginSection();
    }
});

// Auth functions
function showLoginSection() {
    // Use classList to properly show/hide (d-flex uses !important)
    loginSection.classList.remove('d-none');
    loginSection.classList.add('d-flex');
    mainContent.classList.add('d-none');
    mainContent.style.display = 'none';
}

function showMainContent() {
    console.log('showMainContent called');

    if (!loginSection || !mainContent) {
        console.error('DOM elements not found!');
        return;
    }

    // Use classList to properly hide/show (d-flex uses !important)
    loginSection.classList.add('d-none');
    loginSection.classList.remove('d-flex');
    mainContent.classList.remove('d-none');
    mainContent.style.display = 'block';

    document.getElementById('user-email').textContent = currentUser.email;
    loadData();
}

async function handleLogin(e) {
    e.preventDefault();
    const btn = e.target.querySelector('button[type="submit"]');
    btn.classList.add('loading');
    btn.disabled = true;

    const email = document.getElementById('login-email').value;
    const password = document.getElementById('login-password').value;

    try {
        // Check if already logged in
        try {
            currentUser = await account.get();
            showToast('Déjà connecté', 'success');
            showMainContent();
            return;
        } catch (e) {
            // Not logged in, continue with login
        }

        await account.createEmailPasswordSession(email, password);
        currentUser = await account.get();
        showToast('Connexion réussie', 'success');
        showMainContent();
    } catch (error) {
        showToast('Erreur de connexion: ' + error.message, 'danger');
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
    }
}

async function logout() {
    try {
        await account.deleteSession('current');
        currentUser = null;
        showLoginSection();
        showToast('Déconnexion réussie', 'success');
    } catch (error) {
        showToast('Erreur de déconnexion: ' + error.message, 'danger');
    }
}

// Data loading
async function loadData() {
    try {
        await Promise.all([loadManufacturers(), loadWings()]);
        updateStats();
        updateManufacturerSelects();
    } catch (error) {
        showToast('Erreur de chargement: ' + error.message, 'danger');
    }
}

async function loadManufacturers() {
    const response = await databases.listDocuments(
        DATABASE_ID,
        MANUFACTURERS_COLLECTION_ID,
        [Appwrite.Query.orderAsc('displayOrder'), Appwrite.Query.limit(100)]
    );
    manufacturers = response.documents;
    renderManufacturers();
}

async function loadWings() {
    const response = await databases.listDocuments(
        DATABASE_ID,
        WINGS_COLLECTION_ID,
        [Appwrite.Query.orderAsc('displayOrder'), Appwrite.Query.orderAsc('model'), Appwrite.Query.limit(500)]
    );
    wings = response.documents;
    renderWings();
}

// View mode toggle
function setViewMode(mode) {
    viewMode = mode;
    document.getElementById('view-cards').classList.toggle('active', mode === 'cards');
    document.getElementById('view-list').classList.toggle('active', mode === 'list');
    document.getElementById('wings-cards').style.display = mode === 'cards' ? 'flex' : 'none';
    document.getElementById('wings-list').style.display = mode === 'list' ? 'block' : 'none';
    renderWings();
}

// Render functions
function renderManufacturers() {
    const container = document.getElementById('manufacturers-container');

    if (manufacturers.length === 0) {
        container.innerHTML = '<tr><td colspan="5" class="text-center text-muted py-4">Aucun fabricant</td></tr>';
        return;
    }

    container.innerHTML = manufacturers.map((m, index) => {
        const wingCount = wings.filter(w => w.manufacturerId === m.$id).length;
        return `
            <tr class="manufacturer-drag-item"
                draggable="true"
                data-id="${m.$id}"
                data-index="${index}"
                ondragstart="handleManufacturerDragStart(event, '${m.$id}')"
                ondragover="handleManufacturerDragOver(event)"
                ondragenter="handleManufacturerDragEnter(event)"
                ondragleave="handleManufacturerDragLeave(event)"
                ondrop="handleManufacturerDrop(event, '${m.$id}')"
                ondragend="handleManufacturerDragEnd(event)">
                <td class="drag-handle text-center text-muted" style="cursor: grab;" title="Glisser pour réordonner">
                    <i class="bi bi-grip-vertical"></i>
                </td>
                <td><strong>${m.name}</strong></td>
                <td><code class="text-muted">${m.$id}</code></td>
                <td><span class="badge bg-secondary">${wingCount}</span></td>
                <td>
                    <button class="btn btn-sm btn-outline-primary me-1" onclick="editManufacturer('${m.$id}')" title="Modifier">
                        <i class="bi bi-pencil"></i>
                    </button>
                    <button class="btn btn-sm btn-outline-danger" onclick="confirmDeleteManufacturer('${m.$id}', '${m.name}')" title="Supprimer">
                        <i class="bi bi-trash"></i>
                    </button>
                </td>
            </tr>
        `;
    }).join('');
}

// Drag & Drop for manufacturers
function handleManufacturerDragStart(e, id) {
    draggedManufacturerId = id;
    e.target.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', id);
}

function handleManufacturerDragOver(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
}

function handleManufacturerDragEnter(e) {
    e.preventDefault();
    const item = e.target.closest('.manufacturer-drag-item');
    if (item && item.dataset.id !== draggedManufacturerId) {
        item.classList.add('drag-over');
    }
}

function handleManufacturerDragLeave(e) {
    const item = e.target.closest('.manufacturer-drag-item');
    if (item) {
        item.classList.remove('drag-over');
    }
}

function handleManufacturerDragEnd(e) {
    draggedManufacturerId = null;
    document.querySelectorAll('.manufacturer-drag-item').forEach(el => {
        el.classList.remove('dragging', 'drag-over');
    });
}

async function handleManufacturerDrop(e, targetId) {
    e.preventDefault();

    const item = e.target.closest('.manufacturer-drag-item');
    if (item) {
        item.classList.remove('drag-over');
    }

    if (!draggedManufacturerId || draggedManufacturerId === targetId) return;

    // Find indices
    const draggedIndex = manufacturers.findIndex(m => m.$id === draggedManufacturerId);
    const targetIndex = manufacturers.findIndex(m => m.$id === targetId);

    if (draggedIndex === -1 || targetIndex === -1) return;

    // Calculate which items need updating (only those between source and target)
    const minIndex = Math.min(draggedIndex, targetIndex);
    const maxIndex = Math.max(draggedIndex, targetIndex);

    // Reorder locally first for instant feedback
    const [draggedItem] = manufacturers.splice(draggedIndex, 1);
    manufacturers.splice(targetIndex, 0, draggedItem);

    // Only update items that changed position (between min and max)
    const updates = [];
    for (let i = minIndex; i <= maxIndex; i++) {
        const m = manufacturers[i];
        if (m.displayOrder !== i) {
            updates.push({ id: m.$id, displayOrder: i });
        }
    }

    // Update local state
    updates.forEach(u => {
        const mfr = manufacturers.find(m => m.$id === u.id);
        if (mfr) mfr.displayOrder = u.displayOrder;
    });

    // Re-render immediately
    renderManufacturers();

    // Save to database - sequential to avoid rate limit
    if (updates.length > 0) {
        try {
            for (const u of updates) {
                await databases.updateDocument(DATABASE_ID, MANUFACTURERS_COLLECTION_ID, u.id, {
                    displayOrder: u.displayOrder
                });
            }
            showToast('Ordre mis à jour', 'success');
        } catch (error) {
            showToast('Erreur lors de la mise à jour: ' + error.message, 'danger');
            // Reload to get correct order
            await loadManufacturers();
        }
    }
}

// Drag & Drop for wings
function handleWingDragStart(e, id) {
    draggedWingId = id;
    e.target.classList.add('dragging');
    e.dataTransfer.effectAllowed = 'move';
    e.dataTransfer.setData('text/plain', id);
}

function handleWingDragOver(e) {
    e.preventDefault();
    e.dataTransfer.dropEffect = 'move';
}

function handleWingDragEnter(e) {
    e.preventDefault();
    const item = e.target.closest('.wing-drag-item');
    if (item && item.dataset.id !== draggedWingId) {
        item.classList.add('drag-over');
    }
}

function handleWingDragLeave(e) {
    const item = e.target.closest('.wing-drag-item');
    if (item) {
        item.classList.remove('drag-over');
    }
}

function handleWingDragEnd() {
    draggedWingId = null;
    document.querySelectorAll('.wing-drag-item').forEach(el => {
        el.classList.remove('dragging', 'drag-over');
    });
}

async function handleWingDrop(e, targetId) {
    e.preventDefault();

    const item = e.target.closest('.wing-drag-item');
    if (item) {
        item.classList.remove('drag-over');
    }

    if (!draggedWingId || draggedWingId === targetId) return;

    // Get current filtered view
    const filterManufacturer = document.getElementById('filter-manufacturer').value;
    let currentWings = filterManufacturer
        ? wings.filter(w => w.manufacturerId === filterManufacturer)
        : [...wings];

    // Find indices in filtered array
    const draggedIndex = currentWings.findIndex(w => w.$id === draggedWingId);
    const targetIndex = currentWings.findIndex(w => w.$id === targetId);

    if (draggedIndex === -1 || targetIndex === -1) return;

    // Calculate which items need updating (only those between source and target)
    const minIndex = Math.min(draggedIndex, targetIndex);
    const maxIndex = Math.max(draggedIndex, targetIndex);

    // Reorder in filtered array
    const [draggedItem] = currentWings.splice(draggedIndex, 1);
    currentWings.splice(targetIndex, 0, draggedItem);

    // Only update items that changed position (between min and max)
    const updates = [];
    for (let i = minIndex; i <= maxIndex; i++) {
        const w = currentWings[i];
        if (w.displayOrder !== i) {
            updates.push({ id: w.$id, displayOrder: i });
        }
    }

    // Update main wings array with new order
    updates.forEach(u => {
        const wing = wings.find(w => w.$id === u.id);
        if (wing) wing.displayOrder = u.displayOrder;
    });

    // Sort wings array by displayOrder
    wings.sort((a, b) => (a.displayOrder || 0) - (b.displayOrder || 0));

    // Re-render immediately
    renderWings();

    // Save to database - only changed items
    if (updates.length > 0) {
        try {
            // Sequential updates to avoid rate limit
            for (const u of updates) {
                await databases.updateDocument(DATABASE_ID, WINGS_COLLECTION_ID, u.id, {
                    displayOrder: u.displayOrder
                });
            }
            showToast('Ordre des voiles mis à jour', 'success');
        } catch (error) {
            showToast('Erreur lors de la mise à jour: ' + error.message, 'danger');
            // Reload to get correct order
            await loadWings();
        }
    }
}

function renderWings() {
    const filterManufacturer = document.getElementById('filter-manufacturer').value;

    let filteredWings = wings;
    if (filterManufacturer) {
        filteredWings = wings.filter(w => w.manufacturerId === filterManufacturer);
    }

    if (viewMode === 'cards') {
        renderWingsCards(filteredWings);
    } else {
        renderWingsTable(filteredWings);
    }
}

function renderWingsCards(filteredWings) {
    const container = document.getElementById('wings-cards');

    if (filteredWings.length === 0) {
        container.innerHTML = `
            <div class="col-12">
                <div class="empty-state">
                    <i class="bi bi-wind"></i>
                    <p>Aucune voile</p>
                </div>
            </div>
        `;
        return;
    }

    container.innerHTML = filteredWings.map(w => {
        const manufacturer = manufacturers.find(m => m.$id === w.manufacturerId);
        const manufacturerName = manufacturer ? manufacturer.name : w.manufacturerId;
        const imageUrl = w.imageFileId
            ? `${APPWRITE_ENDPOINT}/storage/buckets/${WING_IMAGES_BUCKET_ID}/files/${w.imageFileId}/view?project=${APPWRITE_PROJECT_ID}`
            : '';

        return `
            <div class="col-6 col-md-4 col-lg-3 col-xl-2 wing-drag-item"
                 draggable="true"
                 data-id="${w.$id}"
                 ondragstart="handleWingDragStart(event, '${w.$id}')"
                 ondragover="handleWingDragOver(event)"
                 ondragenter="handleWingDragEnter(event)"
                 ondragleave="handleWingDragLeave(event)"
                 ondrop="handleWingDrop(event, '${w.$id}')"
                 ondragend="handleWingDragEnd(event)">
                <div class="wing-card card">
                    <div class="wing-card-image">
                        <div class="wing-drag-handle" title="Glisser pour réordonner">
                            <i class="bi bi-grip-vertical"></i>
                        </div>
                        ${imageUrl
                            ? `<img src="${imageUrl}" alt="${w.model}">`
                            : `<i class="bi bi-image text-muted" style="font-size: 2rem; opacity: 0.3;"></i>`}
                    </div>
                    <div class="wing-card-body">
                        <div class="wing-card-manufacturer">${manufacturerName}</div>
                        <div class="wing-card-model">${w.model}</div>
                        <span class="wing-card-type">${w.type}</span>
                        <div class="wing-card-sizes">
                            ${(w.sizes || []).map(s => `<span class="size-chip">${s}</span>`).join('')}
                        </div>
                    </div>
                    <div class="wing-card-actions">
                        <button class="btn btn-outline-secondary" onclick="duplicateWing('${w.$id}')" title="Dupliquer">
                            <i class="bi bi-copy"></i>
                        </button>
                        <button class="btn btn-outline-primary" onclick="editWing('${w.$id}')" title="Modifier">
                            <i class="bi bi-pencil"></i>
                        </button>
                        <button class="btn btn-outline-danger" onclick="confirmDeleteWing('${w.$id}', '${manufacturerName} ${w.model}')" title="Supprimer">
                            <i class="bi bi-trash"></i>
                        </button>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

function renderWingsTable(filteredWings) {
    const tbody = document.getElementById('wings-table');

    if (filteredWings.length === 0) {
        tbody.innerHTML = '<tr><td colspan="6" class="text-center text-muted py-5">Aucune voile</td></tr>';
        return;
    }

    tbody.innerHTML = filteredWings.map(w => {
        const manufacturer = manufacturers.find(m => m.$id === w.manufacturerId);
        const manufacturerName = manufacturer ? manufacturer.name : w.manufacturerId;
        const imageUrl = w.imageFileId
            ? `${APPWRITE_ENDPOINT}/storage/buckets/${WING_IMAGES_BUCKET_ID}/files/${w.imageFileId}/view?project=${APPWRITE_PROJECT_ID}`
            : '';

        return `
            <tr>
                <td>
                    ${imageUrl
                        ? `<img src="${imageUrl}" class="table-wing-image" alt="${w.model}">`
                        : '<span class="text-muted">-</span>'}
                </td>
                <td>${manufacturerName}</td>
                <td><strong>${w.model}</strong></td>
                <td><span class="badge bg-secondary">${w.type}</span></td>
                <td>${(w.sizes || []).map(s => `<span class="size-chip">${s}</span>`).join(' ')}</td>
                <td>
                    <button class="btn btn-sm btn-outline-secondary me-1" onclick="duplicateWing('${w.$id}')" title="Dupliquer">
                        <i class="bi bi-copy"></i>
                    </button>
                    <button class="btn btn-sm btn-outline-primary me-1" onclick="editWing('${w.$id}')" title="Modifier">
                        <i class="bi bi-pencil"></i>
                    </button>
                    <button class="btn btn-sm btn-outline-danger" onclick="confirmDeleteWing('${w.$id}', '${manufacturerName} ${w.model}')" title="Supprimer">
                        <i class="bi bi-trash"></i>
                    </button>
                </td>
            </tr>
        `;
    }).join('');
}

function updateStats() {
    document.getElementById('stats-manufacturers').textContent = manufacturers.length;
    document.getElementById('stats-wings').textContent = wings.length;
    const imagesCount = wings.filter(w => w.imageFileId).length;
    document.getElementById('stats-images').textContent = imagesCount;
}

function updateManufacturerSelects() {
    const options = manufacturers.map(m => `<option value="${m.$id}">${m.name}</option>`).join('');

    // Filter select
    const filterSelect = document.getElementById('filter-manufacturer');
    filterSelect.innerHTML = '<option value="">Tous les fabricants</option>' + options;

    // Wing form select
    const wingSelect = document.getElementById('wing-manufacturer');
    wingSelect.innerHTML = '<option value="">Sélectionner...</option>' + options;
}

// Manufacturer CRUD
function showAddManufacturerModal() {
    document.getElementById('manufacturer-modal-title').textContent = 'Ajouter un fabricant';
    document.getElementById('manufacturer-id').value = '';
    document.getElementById('manufacturer-name').value = '';
    document.getElementById('manufacturer-order').value = manufacturers.length;
    manufacturerModal.show();
}

function editManufacturer(id) {
    const m = manufacturers.find(m => m.$id === id);
    if (!m) return;

    document.getElementById('manufacturer-modal-title').textContent = 'Modifier le fabricant';
    document.getElementById('manufacturer-id').value = m.$id;
    document.getElementById('manufacturer-name').value = m.name;
    document.getElementById('manufacturer-order').value = m.displayOrder || 0;
    manufacturerModal.show();
}

async function handleManufacturerSubmit(e) {
    e.preventDefault();
    const btn = e.target.querySelector('button[type="submit"]');
    btn.classList.add('loading');
    btn.disabled = true;

    const id = document.getElementById('manufacturer-id').value;
    const name = document.getElementById('manufacturer-name').value;
    const displayOrder = parseInt(document.getElementById('manufacturer-order').value) || 0;

    try {
        if (id) {
            // Update
            await databases.updateDocument(DATABASE_ID, MANUFACTURERS_COLLECTION_ID, id, {
                name,
                displayOrder
            });
            showToast('Fabricant mis à jour', 'success');
        } else {
            // Create with custom ID
            const newId = name.toLowerCase().replace(/[^a-z0-9]/g, '-').replace(/-+/g, '-');
            await databases.createDocument(DATABASE_ID, MANUFACTURERS_COLLECTION_ID, newId, {
                name,
                displayOrder
            });
            showToast('Fabricant créé', 'success');
        }
        manufacturerModal.hide();
        await loadData();
    } catch (error) {
        showToast('Erreur: ' + error.message, 'danger');
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
    }
}

function confirmDeleteManufacturer(id, name) {
    const wingCount = wings.filter(w => w.manufacturerId === id).length;
    if (wingCount > 0) {
        showToast(`Impossible de supprimer: ${wingCount} voiles sont liées à ce fabricant`, 'warning');
        return;
    }

    document.getElementById('delete-item-name').textContent = name;
    deleteCallback = async () => {
        await databases.deleteDocument(DATABASE_ID, MANUFACTURERS_COLLECTION_ID, id);
        showToast('Fabricant supprimé', 'success');
        await loadData();
    };
    deleteModal.show();
}

// Wing CRUD
function showAddWingModal() {
    document.getElementById('wing-modal-title').textContent = 'Ajouter une voile';
    document.getElementById('wing-id').value = '';
    document.getElementById('wing-image-file-id').value = '';
    document.getElementById('wing-manufacturer').value = '';
    document.getElementById('wing-model').value = '';
    document.getElementById('wing-type').value = '';
    document.getElementById('wing-year').value = '';
    document.getElementById('wing-sizes').value = '';
    document.getElementById('wing-image').value = '';
    document.getElementById('preview-img').classList.add('d-none');
    document.getElementById('preview-placeholder').classList.remove('d-none');
    wingModal.show();
}

function editWing(id) {
    const w = wings.find(w => w.$id === id);
    if (!w) return;

    document.getElementById('wing-modal-title').textContent = 'Modifier la voile';
    document.getElementById('wing-id').value = w.$id;
    document.getElementById('wing-image-file-id').value = w.imageFileId || '';
    document.getElementById('wing-manufacturer').value = w.manufacturerId;
    document.getElementById('wing-model').value = w.model;
    document.getElementById('wing-type').value = w.type;
    document.getElementById('wing-year').value = w.year || '';
    document.getElementById('wing-sizes').value = (w.sizes || []).join(', ');
    document.getElementById('wing-image').value = '';

    // Show current image if exists
    if (w.imageFileId) {
        const imageUrl = `${APPWRITE_ENDPOINT}/storage/buckets/${WING_IMAGES_BUCKET_ID}/files/${w.imageFileId}/view?project=${APPWRITE_PROJECT_ID}`;
        document.getElementById('preview-img').src = imageUrl;
        document.getElementById('preview-img').classList.remove('d-none');
        document.getElementById('preview-placeholder').classList.add('d-none');
    } else {
        document.getElementById('preview-img').classList.add('d-none');
        document.getElementById('preview-placeholder').classList.remove('d-none');
    }

    wingModal.show();
}

// Duplicate wing
function duplicateWing(id) {
    const w = wings.find(w => w.$id === id);
    if (!w) return;

    document.getElementById('wing-modal-title').textContent = 'Dupliquer la voile';
    document.getElementById('wing-id').value = ''; // Empty ID = create new
    document.getElementById('wing-image-file-id').value = ''; // Don't copy image
    document.getElementById('wing-manufacturer').value = w.manufacturerId;
    document.getElementById('wing-model').value = w.model + ' (copie)';
    document.getElementById('wing-type').value = w.type;
    document.getElementById('wing-year').value = w.year || '';
    document.getElementById('wing-sizes').value = (w.sizes || []).join(', ');
    document.getElementById('wing-image').value = '';

    // Show current image if exists (for reference)
    if (w.imageFileId) {
        const imageUrl = `${APPWRITE_ENDPOINT}/storage/buckets/${WING_IMAGES_BUCKET_ID}/files/${w.imageFileId}/view?project=${APPWRITE_PROJECT_ID}`;
        document.getElementById('preview-img').src = imageUrl;
        document.getElementById('preview-img').classList.remove('d-none');
        document.getElementById('preview-placeholder').classList.add('d-none');
    } else {
        document.getElementById('preview-img').classList.add('d-none');
        document.getElementById('preview-placeholder').classList.remove('d-none');
    }

    wingModal.show();
}

function handleImagePreview(e) {
    const file = e.target.files[0];
    if (file) {
        const reader = new FileReader();
        reader.onload = (e) => {
            document.getElementById('preview-img').src = e.target.result;
            document.getElementById('preview-img').classList.remove('d-none');
            document.getElementById('preview-placeholder').classList.add('d-none');
        };
        reader.readAsDataURL(file);
    }
}

async function handleWingSubmit(e) {
    e.preventDefault();
    const btn = e.target.querySelector('button[type="submit"]');
    btn.classList.add('loading');
    btn.disabled = true;

    const id = document.getElementById('wing-id').value;
    const manufacturerId = document.getElementById('wing-manufacturer').value;
    const model = document.getElementById('wing-model').value;
    const type = document.getElementById('wing-type').value;
    const year = document.getElementById('wing-year').value ? parseInt(document.getElementById('wing-year').value) : null;
    const sizes = document.getElementById('wing-sizes').value.split(',').map(s => s.trim()).filter(s => s);
    const imageFile = document.getElementById('wing-image').files[0];
    let imageFileId = document.getElementById('wing-image-file-id').value || null;

    try {
        // Generate ID for new wing
        const newId = id || `${manufacturerId}-${model}`.toLowerCase().replace(/[^a-z0-9]/g, '-').replace(/-+/g, '-');

        // Upload image if provided
        if (imageFile) {
            // Delete old image if exists (only for updates)
            if (id && imageFileId) {
                try {
                    await storage.deleteFile(WING_IMAGES_BUCKET_ID, imageFileId);
                } catch (e) {
                    // Ignore if file doesn't exist
                }
            }

            // Upload new image with wing ID as file ID
            const response = await storage.createFile(WING_IMAGES_BUCKET_ID, newId, imageFile);
            imageFileId = response.$id;
        }

        const data = {
            manufacturerId,
            model,
            type,
            sizes,
            imageFileId
        };

        if (year) {
            data.year = year;
        }

        if (id) {
            // Update
            await databases.updateDocument(DATABASE_ID, WINGS_COLLECTION_ID, id, data);
            showToast('Voile mise à jour', 'success');
        } else {
            // Create with custom ID
            await databases.createDocument(DATABASE_ID, WINGS_COLLECTION_ID, newId, data);
            showToast('Voile créée', 'success');
        }
        wingModal.hide();
        await loadData();
    } catch (error) {
        showToast('Erreur: ' + error.message, 'danger');
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
    }
}

function confirmDeleteWing(id, name) {
    document.getElementById('delete-item-name').textContent = name;
    deleteCallback = async () => {
        const wing = wings.find(w => w.$id === id);

        // Delete image if exists
        if (wing && wing.imageFileId) {
            try {
                await storage.deleteFile(WING_IMAGES_BUCKET_ID, wing.imageFileId);
            } catch (e) {
                // Ignore if file doesn't exist
            }
        }

        await databases.deleteDocument(DATABASE_ID, WINGS_COLLECTION_ID, id);
        showToast('Voile supprimée', 'success');
        await loadData();
    };
    deleteModal.show();
}

async function handleDelete() {
    const btn = document.getElementById('confirm-delete-btn');
    btn.classList.add('loading');
    btn.disabled = true;

    try {
        if (deleteCallback) {
            await deleteCallback();
        }
        deleteModal.hide();
    } catch (error) {
        showToast('Erreur: ' + error.message, 'danger');
    } finally {
        btn.classList.remove('loading');
        btn.disabled = false;
        deleteCallback = null;
    }
}

// Toast notifications
function showToast(message, type = 'info') {
    const container = document.querySelector('.toast-container');
    const id = 'toast-' + Date.now();

    const bgColor = {
        success: '#11998e',
        danger: '#dc3545',
        warning: '#ffc107',
        info: '#667eea'
    }[type] || '#667eea';

    const textColor = type === 'warning' ? '#333' : 'white';

    const html = `
        <div id="${id}" class="toast align-items-center border-0" role="alert" style="background: ${bgColor}; color: ${textColor};">
            <div class="d-flex">
                <div class="toast-body">${message}</div>
                <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button>
            </div>
        </div>
    `;

    container.insertAdjacentHTML('beforeend', html);
    const toastEl = document.getElementById(id);
    const toast = new bootstrap.Toast(toastEl, { delay: 4000 });
    toast.show();

    toastEl.addEventListener('hidden.bs.toast', () => toastEl.remove());
}
